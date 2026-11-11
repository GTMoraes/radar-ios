import SwiftUI

@main
struct RadarApp: App {
    @StateObject private var radar = Radar()

    var body: some Scene {
        WindowGroup {
            InicioView()
                .environmentObject(radar)
                .preferredColorScheme(.dark)
                .tint(Tema.acento)
        }
    }
}
