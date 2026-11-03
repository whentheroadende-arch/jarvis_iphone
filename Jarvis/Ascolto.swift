import Foundation
import AVFoundation

// Ascolta il microfono (anche quello degli occhiali via Bluetooth), taglia le frasi quando smetti di parlare e le manda al PC.
// Con "Ascolta sempre" vale solo se dici "Jarvis" (lo controlla il PC); col tasto premuto tutto quello che dici va a Jarvis.
final class Ascolto: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var stato = "Spento"
    @Published var sentito = ""
    @Published var risposta = ""
    @Published var livello: Float = 0

    private let motore = AVAudioEngine()
    private var convertitore: AVAudioConverter?
    private let formato16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var campioni: [Int16] = []
    private var prima: [Int16] = []
    private var parla = false
    private var silenzio = 0.0
    private var durata = 0.0
    private var fondo = 0.01
    private var occupato = false
    private var premuto = false
    private var attendeComando = false
    private var scadenzaComando = Date.distantPast
    private var lettore: AVAudioPlayer?
    private let sintesi = AVSpeechSynthesizer()
    private var acceso = false

    private var indirizzo: String { UserDefaults.standard.string(forKey: "indirizzo") ?? "100.83.5.38" }
    private var chiave: String { UserDefaults.standard.string(forKey: "chiave") ?? "" }
    private var sempre: Bool { UserDefaults.standard.object(forKey: "sempre") as? Bool ?? true }

    func accendi() {
        if acceso { return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async {
                if ok { self.avviaMotore() } else { self.stato = "Serve il permesso del microfono (Impostazioni > Jarvis)" }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(interrotto(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(cambiaUscita(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
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
            input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in self?.elabora(buf) }
            motore.prepare()
            try motore.start()
            acceso = true
            stato = sempre ? "Aspetto «Jarvis»" : "Tieni premuto e parla"
        } catch {
            stato = "Microfono non disponibile: \(error.localizedDescription)"
        }
    }

    @objc private func interrotto(_ n: Notification) {
        guard let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt, let tipo = AVAudioSession.InterruptionType(rawValue: v) else { return }
        if tipo == .ended { DispatchQueue.main.async { self.riavvia() } }
    }

    @objc private func cambiaUscita(_ n: Notification) {
        // (occhiali collegati o scollegati: il formato del microfono cambia, il motore va rifatto)
        DispatchQueue.main.async { self.riavvia() }
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
        let pezzo = Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
        DispatchQueue.main.async { self.aggiungi(pezzo) }
    }

    private func aggiungi(_ pezzo: [Int16]) {
        if occupato || pezzo.isEmpty { return }
        let somma = pezzo.reduce(0.0) { $0 + Double($1) * Double($1) }
        let rms = (somma / Double(pezzo.count)).squareRoot() / 32768.0
        livello = Float(rms)
        let secondi = Double(pezzo.count) / 16000.0
        let soglia = max(0.02, fondo * 3)
        if !parla {
            fondo = 0.97 * fondo + 0.03 * rms
            prima.append(contentsOf: pezzo)
            if prima.count > 5600 { prima.removeFirst(prima.count - 5600) }
            if attendeComando && Date() > scadenzaComando { attendeComando = false; stato = "Aspetto «Jarvis»" }
            if premuto || ((sempre || attendeComando) && rms > soglia) {
                parla = true; campioni = prima; prima = []; silenzio = 0; durata = 0
            }
            return
        }
        campioni.append(contentsOf: pezzo)
        durata += secondi
        silenzio = rms > soglia ? 0 : silenzio + secondi
        if (!premuto && silenzio > 0.8) || durata > 12 {
            parla = false
            let frase = campioni
            campioni = []
            if durata - silenzio < 0.35 { return }
            invia(frase, sveglia: !attendeComando)
        }
    }

    func iniziaPremuto() {
        if premuto || occupato { return }
        premuto = true
        parla = true; campioni = prima; prima = []; silenzio = 0; durata = 0
        stato = "Ti ascolto…"
    }

    func finePremuto() {
        if !premuto { return }
        premuto = false
        if parla {
            parla = false
            let frase = campioni
            campioni = []
            if frase.count > 4000 { invia(frase, sveglia: false) } else { stato = "Troppo corto" }
        }
    }

    private func invia(_ frase: [Int16], sveglia: Bool) {
        guard let url = URL(string: "http://\(indirizzo):8191/frase?sveglia=\(sveglia ? 1 : 0)") else { stato = "Indirizzo del PC sbagliato"; return }
        occupato = true
        stato = sveglia ? "Sento…" : "Ci penso…"
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue(chiave, forHTTPHeaderField: "X-Chiave")
        r.httpBody = wav(frase)
        URLSession.shared.dataTask(with: r) { d, risp, err in
            DispatchQueue.main.async { self.ricevi(d, risp as? HTTPURLResponse, err) }
        }.resume()
    }

    private func ricevi(_ d: Data?, _ r: HTTPURLResponse?, _ err: Error?) {
        guard let r = r else { occupato = false; stato = "PC non raggiungibile (Tailscale acceso?)"; return }
        switch r.statusCode {
        case 204:
            occupato = false
            stato = attendeComando ? "Ti ascolto" : (sempre ? "Aspetto «Jarvis»" : "Tieni premuto e parla")
        case 403:
            occupato = false
            stato = "Chiave sbagliata: controllala in Collegamento al PC"
        case 200:
            let tipo = r.value(forHTTPHeaderField: "Content-Type") ?? ""
            if tipo.contains("json") {
                attendeComando = true
                scadenzaComando = Date().addingTimeInterval(8)
                dici("Dimmi")
                stato = "Ti ascolto"
            } else {
                attendeComando = false
                sentito = (r.value(forHTTPHeaderField: "X-Sentito") ?? "").removingPercentEncoding ?? ""
                risposta = (r.value(forHTTPHeaderField: "X-Testo") ?? "").removingPercentEncoding ?? ""
                suona(d ?? Data())
            }
        default:
            occupato = false
            stato = "Errore \(r.statusCode) dal PC"
        }
    }

    private func suona(_ d: Data) {
        do {
            lettore = try AVAudioPlayer(data: d)
            lettore?.delegate = self
            lettore?.play()
            stato = "Jarvis parla…"
        } catch {
            occupato = false
            stato = "Non riesco a suonare la risposta"
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.occupato = false
            self.stato = self.sempre ? "Aspetto «Jarvis»" : "Tieni premuto e parla"
        }
    }

    private func dici(_ t: String) {
        let u = AVSpeechUtterance(string: t)
        u.voice = AVSpeechSynthesisVoice(language: "it-IT")
        sintesi.speak(u)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { self.occupato = false }
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
