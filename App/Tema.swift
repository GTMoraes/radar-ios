import SwiftUI

/// Cores do app (mesmo esquema escuro dos outros apps, com acento turquesa de radar).
enum Tema {
    static let acento = Color(red: 0.36, green: 0.86, blue: 0.80)        // #5CDBCC
    static let fundo = Color(red: 0.051, green: 0.051, blue: 0.051)      // #0D0D0D
    static let alerta = Color(red: 1.0, green: 0.82, blue: 0.40)

    static var gradiente: some View {
        ZStack {
            fundo
            RadialGradient(colors: [acento.opacity(0.22), .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.20, green: 0.45, blue: 1.0).opacity(0.16), .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 480)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func telaEscura() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Tema.gradiente)
    }
}

/// Barra de sinal: -100 dBm vazia, -35 dBm cheia.
struct BarraSinal: View {
    let valor: Double

    var body: some View {
        let x = min(max((valor + 100) / 65, 0), 1)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(Tema.acento).frame(width: max(g.size.width * x, 8))
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.3), value: x)
    }
}

/// Tradução aproximada do sinal em distância. Varia muito com paredes, corpo e posição do rastreador.
enum Proximidade {
    static func texto(_ m: Double) -> String {
        if m >= -50 { return "muito perto" }
        if m >= -62 { return "perto (mesmo cômodo?)" }
        if m >= -75 { return "médio (cômodo ao lado?)" }
        return "longe"
    }
}

enum Formatos {
    static let hora: DateFormatter = fazer("HH:mm:ss")
    static let horaMs: DateFormatter = fazer("HH:mm:ss.SSS")
    static let dataHora: DateFormatter = fazer("dd/MM/yyyy HH:mm:ss")
    static let arquivo: DateFormatter = fazer("yyyyMMdd-HHmmss")

    private static func fazer(_ formato: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = formato
        return f
    }
}

func hexString(_ b: [UInt8]) -> String {
    b.map { String(format: "%02X", $0) }.joined()
}
