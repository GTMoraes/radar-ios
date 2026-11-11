import Foundation

/// Grava o que o radar vê num CSV (separado por ";") em Documentos/Registros, que aparece no app
/// Arquivos › No Meu iPhone › Radar. Escreve em blocos, para não gastar o disco a cada pacote.
@MainActor
final class Registro {
    private(set) var url: URL
    private(set) var nomeArquivo: String
    private(set) var linhas = 0
    private var pendente: [String] = []
    private var handle: FileHandle?

    init() {
        let criado = Registro.criar()
        url = criado.url
        nomeArquivo = criado.nome
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    private static func criar() -> (url: URL, nome: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let pasta = docs.appendingPathComponent("Registros", isDirectory: true)
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let nome = "radar-\(Formatos.arquivo.string(from: Date())).csv"
        let u = pasta.appendingPathComponent(nome)
        let cabecalho = "hora;tipo;id;rssi;classe;estado;status;bateria;tipo_pelo_status;inicio_chave;nome;dados\n"
        FileManager.default.createFile(atPath: u.path, contents: Data(cabecalho.utf8))
        return (u, nome)
    }

    func anotarPacote(_ hora: Date, id: UUID, rssi: Int, _ l: Leitura) {
        let campos = [
            Formatos.horaMs.string(from: hora), "PACOTE", id.uuidString, String(rssi),
            limpar(l.rotulo), l.estado, l.status.map { String(format: "%02X", $0) } ?? "",
            l.bateria, l.tipoPeloStatus, l.idChave, limpar(l.nome), l.dadosHex,
        ]
        escrever(campos.joined(separator: ";"))
    }

    /// Linha livre: "MARCA 2", "EVENTO;...", "RSSI_CONEXAO;id;-48"...
    func anotarLinha(_ s: String) {
        escrever(Formatos.horaMs.string(from: Date()) + ";" + s)
    }

    private func escrever(_ s: String) {
        pendente.append(s)
        linhas += 1
        if pendente.count >= 500 { descarregar() }
    }

    func descarregar() {
        guard !pendente.isEmpty else { return }
        let texto = pendente.joined(separator: "\n") + "\n"
        pendente.removeAll(keepingCapacity: true)
        try? handle?.write(contentsOf: Data(texto.utf8))
    }

    private func limpar(_ s: String) -> String {
        s.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "\n", with: " ")
    }
}
