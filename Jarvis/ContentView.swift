import SwiftUI

struct ContentView: View {
    @EnvironmentObject var a: Ascolto
    @AppStorage("indirizzo") private var indirizzo = "100.83.5.38"
    @AppStorage("chiave") private var chiave = ""
    @AppStorage("sempre") private var sempre = true

    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.03, blue: 0.05).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    Text("Jarvis").font(.largeTitle.bold()).foregroundColor(.white).padding(.top, 24)
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 0.55, green: 0.85, blue: 1), Color(red: 0.04, green: 0.12, blue: 0.2)], center: .center, startRadius: 4, endRadius: 90))
                        .overlay(Circle().stroke(Color.cyan.opacity(0.6), lineWidth: 2))
                        .frame(width: 170, height: 170)
                        .scaleEffect(1 + CGFloat(min(a.livello * 6, 0.25)))
                        .animation(.easeOut(duration: 0.15), value: a.livello)
                    Text(a.stato).foregroundColor(.cyan).multilineTextAlignment(.center)
                    if !a.batteria.isEmpty { Text("Batteria: \(a.batteria)").font(.footnote).foregroundColor(.white.opacity(0.6)) }
                    if !a.sentito.isEmpty { Text("Tu: \(a.sentito)").foregroundColor(.white.opacity(0.75)).frame(maxWidth: .infinity, alignment: .leading) }
                    if !a.risposta.isEmpty { Text("Jarvis: \(a.risposta)").foregroundColor(.white).frame(maxWidth: .infinity, alignment: .leading) }
                    Toggle("Ascolta sempre «Jarvis»", isOn: $sempre).tint(.cyan).foregroundColor(.white)
                    Text("Tieni premuto e parla")
                        .bold().foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 22)
                        .background(Color.cyan.opacity(0.22)).cornerRadius(16)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in a.iniziaPremuto() }.onEnded { _ in a.finePremuto() })
                    DisclosureGroup("Collegamento al PC") {
                        VStack(spacing: 10) {
                            TextField("Indirizzo del PC (Tailscale)", text: $indirizzo)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                                .padding(10).background(Color.white.opacity(0.08)).cornerRadius(8)
                            SecureField("Chiave (te la manda Jarvis su Telegram)", text: $chiave)
                                .padding(10).background(Color.white.opacity(0.08)).cornerRadius(8)
                            Button("Prova il collegamento") { a.prova() }.foregroundColor(.cyan)
                        }.padding(.top, 8)
                    }
                    .foregroundColor(.white).tint(.cyan)
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { a.accendi() }
    }
}
