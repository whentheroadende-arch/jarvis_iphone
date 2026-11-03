import Foundation
import AVFoundation
import UIKit

// Ascolta il microfono (anche quello degli occhiali via Bluetooth), taglia le frasi quando smetti di parlare e le manda al PC.
// Con "Ascolta sempre" il PC risponde solo se dici "Jarvis"; il resto lo trascrive per gli appunti delle lezioni (3/11). Col tasto premuto tutto va a Jarvis.
// (3/11 mattina) Il microfono resta acceso anche mentre aspetta il PC o mentre Jarvis parla: cosi' "Jarvis stop" lo zittisce subito e le lezioni non perdono pezzi.
// Batteria: il lavoro sul suono si fa fuori dal thread principale, la sfera si aggiorna al massimo 10 volte al secondo e solo con l'app davanti, e il consumo
// (percento all'ora) si misura e va al PC; sotto il 20% o oltre il 12%/ora passa al risparmio (soglia piu' alta, frasi piu' corte).
final class Ascolto: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var stato = "Spento"
    @Published var sentito = ""
    @Published var risposta = ""
    @Published var livello: Float = 0
    @Published var batteria = ""

    private let motore = AVAudioEngine()
    private var convertitore: AVAudioConverter?
    private let formato16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let coda = DispatchQueue(label: "jarvis.suono")
    // (stato del taglio delle frasi: lo tocca solo la coda del suono)
    private var campioni: [Int16] = []
    private var prima: [Int16] = []
    private var parla = false
    private var silenzio = 0.0
    private var durata = 0.0
    private var fondo = 0.01
    private var premuto = false
    private var ultimoLivello = Date.distantPast
    // (stato dell'invio e della voce: lo tocca solo il thread principale)
    private var inVolo = 0
    private var attendeComando = false
    private var scadenzaComando = Date.distantPast
    private var lettore: AVAudioPlayer?
    private let sintesi = AVSpeechSynthesizer()
    private var acceso = false
    private var risparmio = false
    private var misure: [(Date, Float)] = []

    private var indirizzo: String { UserDefaults.standard.string(forKey: "indirizzo") ?? "100.83.5.38" }
    private var chiave: String { UserDefaults.standard.string(forKey: "chiave") ?? "" }
    private var sempre: Bool { UserDefaults.standard.object(forKey: "sempre") as? Bool ?? true }
    private var pronto: String { sempre ? "Aspetto «Jarvis»" : "Tieni premuto e parla" }

    func accendi() {
        if acceso { return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async {
                if ok { self.avviaMotore() } else { self.stato = "Serve il permesso del microfono (Impostazioni > Jarvis)" }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interrotto(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cambiaUscita(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        UIDevice.current.isBatteryMonitoringEnabled = true
        misuraBatteria()
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.misuraBatteria() }
    }

    private func avviaMotore() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
            try s.setActive(true)
            let input = motore.inputNode
            input.removeTap(onBus: 0)
            let fmt = input.outputFormat(forBus: 0)
            convertitore = AVAudioConverter(from: fmt, to: formato16)
            // (4096 campioni = meno risvegli del processore che 2048, stessa qualita')
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in self?.coda.async { self?.elabora(buf) } }
            motore.prepare()
            try motore.start()
            acceso = true
            stato = pronto
        } catch {
            stato = "Microfono non disponibile: \(error.localizedDescription)"
        }
    }

    @objc private func interrotto(_ n: Notification) {
        guard let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let tipo = AVAudioSession.InterruptionType(rawValue: v) else { return }
        if tipo == .ended { DispatchQueue.main.async { self.riavvia() } }
    }

    @objc private func cambiaUscita(_ n: Notification) {
        // (3/11: prima ogni cambio rifaceva il motore, anche quelli causati dal motore stesso (categoria, altoparlante): ripartiva a vuoto.
        // Ora solo quando si collegano o si scollegano davvero gli occhiali o le cuffie)
        guard let v = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, let motivo = AVAudioSession.RouteChangeReason(rawValue: v) else { return }
        if motivo == .newDeviceAvailable || motivo == .oldDeviceUnavailable { DispatchQueue.main.async { self.riavvia() } }
    }

    private func riavvia() {
        motore.stop()
        motore.inputNode.removeTap(onBus: 0)
        avviaMotore()
    }

    private func elabora(_ buf: AVAudioPCMBuffer) {
        guard let conv = convertitore else { return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * formato16.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: formato16, frameCapacity: cap) else { return }
        var dato = false
        var errore: NSError?
        conv.convert(to: out, error: &errore) { _, st in
            if dato { st.pointee = .noDataNow; return nil }
            dato = true
            st.pointee = .haveData
            return buf
        }
        guard errore == nil, let p = out.int16ChannelData?[0] else { return }
        aggiungi(Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength))))
    }

    // (sulla coda del suono)
    private func aggiungi(_ pezzo: [Int16]) {
        if pezzo.isEmpty { return }
        let somma = pezzo.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (somma / Double(pezzo.count)).squareRoot() / 32768.0
        if Date().timeIntervalSince(ultimoLivello) > 0.1 {
            ultimoLivello = Date()
            let l = Float(rms)
            DispatchQueue.main.async { if UIApplication.shared.applicationState == .active { self.livello = l } }
        }
        let secondi = Double(pezzo.count) / 16000.0
        // (in classe la voce del professore arriva piano: soglia bassa; col risparmio piu' alta)
        let soglia = risparmio ? max(0.02, fondo * 3) : max(0.008, fondo * 2.5)
        let massimo = risparmio ? 12.0 : 20.0
        if !parla {
            fondo = 0.97 * fondo + 0.03 * rms
            prima.append(contentsOf: pezzo)
            if prima.count > 5600 { prima.removeFirst(prima.count - 5600) }
            let attende = attendeComando && Date() < scadenzaComando
            if premuto || ((sempre || attende) && rms > soglia) {
                parla = true; campioni = prima; prima = []; silenzio = 0; durata = 0
            }
            return
        }
        campioni.append(contentsOf: pezzo)
        durata += secondi
        silenzio = rms > soglia ? 0 : silenzio + secondi
        if (!premuto && silenzio > 0.8) || durata > massimo {
            parla = false
            let frase = campioni
            campioni = []
            if durata - silenzio < 0.35 { return }
            DispatchQueue.main.async {
                let comando = self.attendeComando && Date() < self.scadenzaComando
                self.invia(frase, sveglia: !comando)
            }
        }
    }

    func iniziaPremuto() {
        coda.async {
            if self.premuto { return }
            self.premuto = true
            self.parla = true; self.campioni = self.prima; self.prima = []; self.silenzio = 0; self.durata = 0
        }
        zitto()
        stato = "Ti ascolto…"
    }

    func finePremuto() {
        coda.async {
            if !self.premuto { return }
            self.premuto = false
            if self.parla {
                self.parla = false
                let frase = self.campioni
                self.campioni = []
                DispatchQueue.main.async { if frase.count > 4000 { self.invia(frase, sveglia: false) } else { self.stato = "Troppo corto" } }
            }
        }
    }

    private func invia(_ frase: [Int16], sveglia: Bool) {
        // (parla=1: mentre Jarvis parla il microfono sente anche lui; il PC non lo mette negli appunti delle lezioni)
        let staParlando = lettore?.isPlaying == true || sintesi.isSpeaking
        guard let url = URL(string: "http://\(indirizzo):8191/frase?sveglia=\(sveglia ? 1 : 0)&parla=\(staParlando ? 1 : 0)") else { stato = "Indirizzo del PC sbagliato"; return }
        // (al massimo 3 frasi in viaggio: se il PC e' lento non si accumula)
        if inVolo >= 3 { return }
        inVolo += 1
        if !sveglia { stato = "Ci penso…" }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue(chiave, forHTTPHeaderField: "X-Chiave")
        r.setValue(batteria, forHTTPHeaderField: "X-Batteria")
        r.httpBody = wav(frase)
        URLSession.shared.dataTask(with: r) { d, risp, err in
            DispatchQueue.main.async { self.inVolo -= 1; self.ricevi(d, risp as? HTTPURLResponse, err) }
        }.resume()
    }

    private func ricevi(_ d: Data?, _ r: HTTPURLResponse?, _ err: Error?) {
        guard let r = r else { stato = "PC non raggiungibile (Tailscale acceso? Firewall del PC?)"; return }
        switch r.statusCode {
        case 204:
            if lettore?.isPlaying != true { stato = attendeComando && Date() < scadenzaComando ? "Ti ascolto" : pronto }
        case 403:
            stato = "Chiave sbagliata: controllala in Collegamento al PC"
        case 200:
            let tipo = r.value(forHTTPHeaderField: "Content-Type") ?? ""
            if tipo.contains("json") {
                let testo = String(data: d ?? Data(), encoding: .utf8) ?? ""
                if testo.contains("\"stop\"") {
                    // ("Jarvis stop": zitto subito, resta in ascolto e parla solo se lo chiami)
                    zitto()
                    attendeComando = false
                    stato = "Zitto. Ti ascolto: chiamami con «Jarvis»"
                } else {
                    attendeComando = true
                    scadenzaComando = Date().addingTimeInterval(8)
                    dici("Dimmi")
                    stato = "Ti ascolto"
                }
            } else {
                attendeComando = false
                sentito = (r.value(forHTTPHeaderField: "X-Sentito") ?? "").removingPercentEncoding ?? ""
                risposta = (r.value(forHTTPHeaderField: "X-Testo") ?? "").removingPercentEncoding ?? ""
                suona(d ?? Data())
            }
        default:
            stato = "Errore \(r.statusCode) dal PC"
        }
    }

    private func zitto() {
        lettore?.stop()
        lettore = nil
        if sintesi.isSpeaking { sintesi.stopSpeaking(at: .immediate) }
    }

    private func suona(_ d: Data) {
        do {
            lettore = try AVAudioPlayer(data: d)
            lettore?.delegate = self
            lettore?.play()
            stato = "Jarvis parla…"
        } catch {
            stato = "Non riesco a suonare la risposta"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stato = self.pronto }
    }

    private func dici(_ t: String) {
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: "it-IT")
        sintesi.speak(u)
    }

    // (consumo: una misura ogni 5 minuti; il percento all'ora si calcola sull'ultima ora, solo mentre non e' in carica)
    private func misuraBatteria() {
        let d = UIDevice.current
        guard d.batteryLevel >= 0 else { batteria = ""; return }
        if d.batteryState == .charging || d.batteryState == .full { misure = []; risparmio = false; batteria = "In carica (\(Int(d.batteryLevel * 100))%)"; return }
        misure.append((Date(), d.batteryLevel))
        misure = misure.filter { Date().timeIntervalSince($0.0) < 3700 }
        var ora: Double = 0
        if let p = misure.first, let u = misure.last, u.0.timeIntervalSince(p.0) > 900 {
            ora = Double(p.1 - u.1) * 100 / (u.0.timeIntervalSince(p.0) / 3600)
        }
        let nuovo = d.batteryLevel < 0.2 || ora > 12
        coda.async { self.risparmio = nuovo }
        batteria = "\(Int(d.batteryLevel * 100))%" + (ora > 0 ? String(format: ", %.0f%%/ora", ora) : "") + (nuovo ? ", risparmio" : "")
    }

    func prova() {
        guard let url = URL(string: "http://\(indirizzo):8191/ciao") else { stato = "Indirizzo del PC sbagliato"; return }
        var r = URLRequest(url: url)
        r.timeoutInterval = 10
        r.setValue(chiave, forHTTPHeaderField: "X-Chiave")
        stato = "Provo…"
        URLSession.shared.dataTask(with: r) { _, risp, err in
            DispatchQueue.main.async {
                let c = (risp as? HTTPURLResponse)?.statusCode ?? 0
                self.stato = c == 200 ? "Collegato al PC" : c == 403 ? "Chiave sbagliata" : "PC non raggiungibile: \(err?.localizedDescription ?? "codice \(c)")"
            }
        }.resume()
    }

    private func wav(_ s: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        let n = UInt32(s.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + n); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(n)
        s.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}
