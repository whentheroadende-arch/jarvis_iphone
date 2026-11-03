import SwiftUI

// Jarvis sull'iPhone e negli occhiali: l'app ascolta, manda la frase al PC (via Tailscale) e fa sentire la risposta.
@main
struct JarvisApp: App {
    @StateObject private var ascolto = Ascolto()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(ascolto)
        }
    }
}
