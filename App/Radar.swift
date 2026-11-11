import Foundation
import CoreBluetooth
import AudioToolbox
import UIKit

/// Um aparelho visto na varredura. No iPhone o "id" é um identificador que o iOS inventa para cada endereço
/// Bluetooth: quando o rastreador troca de endereço, aparece como um id novo.
struct ItemAnuncio: Identifiable {
    let id: UUID
    var classe: Classe = .outro
    var rotulo = ""
    var estado = ""
    var status: UInt8?
    var bateria = ""
    var tipoPeloStatus = ""
    var idChave = ""
    var nome = ""
    var dadosHex = ""
    var conectavel: Bool?
    var ultimo = 0
    var media = 0.0
    var maximo = -200
    var minimo = 0
    var pacotes = 0
    var pacotesPorSegundo = 0.0
    var primeira = Date()
    var ultima = Date()
    var estados: [(Date, String)] = []
}

/// Um aparelho que o iPhone mantém conectado (achado pelo serviço) e que o app pode medir pela conexão.
struct ItemConectado: Identifiable {
    let id: UUID
    var nome: String
    var bateuEm: [String]
    var estado = "não medido"
    var rssi: Int?
    var media: Double?
    var maximo: Int?
    var servicos: [String] = []
    var leituras: [String] = []
}

struct Marca: Identifiable {
    let id = UUID()
    let numero: Int
    let hora: Date
}

private final class Acumulado {
    var item: ItemAnuncio
    var recentes: [Date] = []
    var amostras: [(Date, Int)] = []
    var ultimoRegistro = Date.distantPast

    init(item: ItemAnuncio) { self.item = item }

    func atualizar(_ l: Leitura, rssi: Int, agora: Date) {
        item.ultima = agora
        item.pacotes += 1
        item.ultimo = rssi
        item.media = item.pacotes == 1 ? Double(rssi) : item.media * 0.7 + Double(rssi) * 0.3
        item.maximo = max(item.maximo, rssi)
        item.minimo = item.pacotes == 1 ? rssi : min(item.minimo, rssi)
        recentes.append(agora)
        recentes.removeAll { agora.timeIntervalSince($0) > 5 }
        if amostras.count < 60_000 { amostras.append((agora, rssi)) }

        // um pacote mais "interessante" que o anterior manda na classificação
        if l.classe >= item.classe {
            item.classe = l.classe
            item.rotulo = l.rotulo
        }
        if l.classe == item.classe {
            if !l.estado.isEmpty && l.estado != item.estado {
                item.estados.append((agora, l.estado))
                item.estado = l.estado
            }
            if let s = l.status { item.status = s; item.bateria = l.bateria; item.tipoPeloStatus = l.tipoPeloStatus }
            if !l.idChave.isEmpty { item.idChave = l.idChave }
            item.dadosHex = l.dadosHex
        }
        if !l.nome.isEmpty { item.nome = l.nome }
        if let c = l.conectavel { item.conectavel = c }
    }
}

/// O motor do app: varre os anúncios, procura o que está conectado ao iPhone, mede o sinal pela conexão e ouve
/// os eventos de conexão do sistema. Tudo roda na fila principal.
@MainActor
final class Radar: NSObject, ObservableObject {
    @Published private(set) var estadoBluetooth = "iniciando"
    @Published private(set) var varrendo = false
    @Published private(set) var anuncios: [ItemAnuncio] = []
    @Published private(set) var seguido: ItemAnuncio?
    @Published private(set) var conectados: [ItemConectado] = []
    @Published private(set) var eventos: [String] = []
    @Published private(set) var marcas: [Marca] = []
    @Published private(set) var totalPacotes = 0
    @Published private(set) var ouvindoConexoes = ""
    @Published var mostrarTodos = false
    @Published var limiar = -65
    @Published var seguindo: UUID?
    @Published var seguindoConexao: UUID?
    @Published var som = true
    @Published var vibrar = true

    let registro = Registro()
    let inicio = Date()

    private var central: CBCentralManager!
    private var acumulados: [UUID: Acumulado] = [:]
    private var perifericos: [UUID: CBPeripheral] = [:]
    private var contadorPacotes = 0
    private var laco: Task<Void, Never>?
    private var lacoRSSI: Task<Void, Never>?
    private var lacoSom: Task<Void, Never>?
    private let gerador = UIImpactFeedbackGenerator(style: .light)

    /// Serviços procurados entre os aparelhos conectados ao iPhone (um de cada vez, para saber qual bateu).
    static let candidatos: [(nome: String, uuid: CBUUID)] = [
        ("Find My (FD44)", CBUUID(string: "FD44")),
        ("Find My não-dono", CBUUID(string: "15190001-12F4-C226-88ED-2AC5579F2A85")),
        ("AirTag som", CBUUID(string: "7DFC9000-7D1C-4951-86AA-8D9728F8D66C")),
        ("Bateria (180F)", CBUUID(string: "180F")),
        ("Informações (180A)", CBUUID(string: "180A")),
        ("Alerta imediato (1802)", CBUUID(string: "1802")),
        ("Perda de conexão (1803)", CBUUID(string: "1803")),
        ("Potência (1804)", CBUUID(string: "1804")),
        ("Google Fast Pair (FE2C)", CBUUID(string: "FE2C")),
        ("FFE0", CBUUID(string: "FFE0")),
        ("FFF0", CBUUID(string: "FFF0")),
        ("FEE7", CBUUID(string: "FEE7")),
        ("Acesso genérico (1800)", CBUUID(string: "1800")),
        ("Atributos genéricos (1801)", CBUUID(string: "1801")),
    ]

    /// Características padrão que dá para ler sem pareamento (bateria, modelo, fabricante, versões).
    static let legiveis: Set<String> = ["2A19", "2A24", "2A26", "2A27", "2A28", "2A29"]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        laco = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self else { return }
                self.publicar()
            }
        }
        lacoSom = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let espera = self.tique()
                try? await Task.sleep(nanoseconds: UInt64(espera * 1_000_000_000))
            }
        }
        anotarEvento("App aberto · registro \(registro.nomeArquivo)")
    }

    // MARK: varredura

    func comecar() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        varrendo = true
    }

    func parar() {
        central.stopScan()
        varrendo = false
        registro.anotarLinha("EVENTO;varredura pausada")
    }

    func voltouAoApp() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        comecar()
    }

    func marcar() {
        let n = (marcas.last?.numero ?? 0) + 1
        marcas.append(Marca(numero: n, hora: Date()))
        registro.anotarLinha("MARCA \(n)")
        anotarEvento("Marca \(n)")
    }

    private func publicar() {
        let agora = Date()
        totalPacotes = contadorPacotes
        var lista: [ItemAnuncio] = []
        for a in acumulados.values {
            a.recentes.removeAll { agora.timeIntervalSince($0) > 5 }
            a.item.pacotesPorSegundo = Double(a.recentes.count) / 5
            guard agora.timeIntervalSince(a.item.ultima) <= 120 else { continue }
            guard a.item.classe.interessante || mostrarTodos || a.item.media >= Double(limiar) else { continue }
            lista.append(a.item)
        }
        lista.sort { x, y in
            if x.classe.interessante != y.classe.interessante { return x.classe.interessante }
            return x.media > y.media
        }
        anuncios = lista
        if let id = seguindo { seguido = acumulados[id]?.item } else if seguido != nil { seguido = nil }
        registro.descarregar()
    }

    // MARK: som e vibração do modo Seguir (tipo contador Geiger: mais perto, mais rápido)

    private func tique() -> Double {
        var media: Double?
        if let id = seguindoConexao, let c = conectados.first(where: { $0.id == id }), c.estado.hasPrefix("conectado") {
            media = c.media
        } else if let s = seguido, Date().timeIntervalSince(s.ultima) < 5 {
            media = s.media
        }
        guard let m = media else { return 0.5 }
        let x = min(max((m + 95) / 55, 0), 1)     // 0 = longe (-95 dBm), 1 = colado (-40 dBm)
        if som { AudioServicesPlaySystemSound(1104) }
        if vibrar { gerador.impactOccurred(intensity: 0.35 + 0.65 * x) }
        return 1.5 - x * 1.42
    }

    // MARK: aparelhos conectados ao iPhone

    func procurarConectados() {
        guard central.state == .poweredOn else { anotarEvento("O Bluetooth não está ligado"); return }
        var achados: [UUID: (p: CBPeripheral, servicos: [String])] = [:]
        var resumo: [String] = []
        for c in Self.candidatos {
            let ps = central.retrieveConnectedPeripherals(withServices: [c.uuid])
            resumo.append("\(c.nome): \(ps.count)")
            for p in ps {
                var e = achados[p.identifier] ?? (p, [])
                e.servicos.append(c.nome)
                achados[p.identifier] = e
            }
        }
        anotarEvento("Procura de conectados · " + resumo.joined(separator: " · "))

        var nova: [ItemConectado] = []
        for (id, e) in achados {
            perifericos[id] = e.p
            var item = conectados.first(where: { $0.id == id }) ?? ItemConectado(id: id, nome: e.p.name ?? "(sem nome)", bateuEm: [])
            if let n = e.p.name { item.nome = n }
            item.bateuEm = e.servicos
            nova.append(item)
            registro.anotarLinha("CONECTADO;\(id.uuidString);\(limpar(item.nome));\(e.servicos.joined(separator: ","))")
        }
        // o que o app está medindo continua na lista, mesmo que a procura não ache de novo
        for antigo in conectados where achados[antigo.id] == nil && antigo.estado.hasPrefix("conectado") {
            nova.append(antigo)
        }
        conectados = nova.sorted { $0.nome < $1.nome }
        if achados.isEmpty { anotarEvento("Nenhum aparelho conectado com esses serviços") }
    }

    /// Conecta (a conexão do sistema é compartilhada) e passa a ler o sinal 3 vezes por segundo.
    func medir(_ id: UUID) {
        guard let p = perifericos[id] else { anotarEvento("Esse aparelho não está mais disponível"); return }
        p.delegate = self
        mudarConectado(id) { $0.estado = "conectando…" }
        central.connect(p, options: nil)
        anotarEvento("Conectando: \(p.name ?? id.uuidString)")
    }

    /// Mede pela conexão um aparelho que apareceu na aba Anúncios.
    func medirAnunciado(_ id: UUID) {
        guard let p = perifericos[id] else { return }
        if !conectados.contains(where: { $0.id == id }) {
            let nome = p.name ?? acumulados[id]?.item.rotulo ?? "(sem nome)"
            conectados.append(ItemConectado(id: id, nome: nome, bateuEm: ["visto nos anúncios"]))
        }
        seguindoConexao = id
        medir(id)
    }

    func pararMedicao(_ id: UUID) {
        guard let p = perifericos[id] else { return }
        if seguindoConexao == id { seguindoConexao = nil }
        central.cancelPeripheralConnection(p)
    }

    private func mudarConectado(_ id: UUID, _ mudar: (inout ItemConectado) -> Void) {
        if let i = conectados.firstIndex(where: { $0.id == id }) { mudar(&conectados[i]) }
    }

    private func garantirLacoRSSI() {
        guard lacoRSSI == nil else { return }
        lacoRSSI = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let self else { return }
                var algum = false
                for item in self.conectados {
                    if let p = self.perifericos[item.id], p.state == .connected {
                        p.readRSSI()
                        algum = true
                    }
                }
                if !algum { self.lacoRSSI = nil; return }
            }
        }
    }

    // MARK: eventos de conexão do sistema

    func ouvirConexoes(soRastreadores: Bool) {
        guard central.state == .poweredOn else { anotarEvento("O Bluetooth não está ligado"); return }
        if soRastreadores {
            central.registerForConnectionEvents(options: [.serviceUUIDs: Self.candidatos.map { $0.uuid }])
            ouvindoConexoes = "só serviços de rastreador"
        } else {
            central.registerForConnectionEvents(options: nil)
            ouvindoConexoes = "todas"
        }
        anotarEvento("Ouvindo conexões: \(ouvindoConexoes)")
    }

    // MARK: texto

    func anotarEvento(_ s: String) {
        eventos.insert("\(Formatos.hora.string(from: Date()))  \(s)", at: 0)
        if eventos.count > 400 { eventos.removeLast(eventos.count - 400) }
        registro.anotarLinha("EVENTO;" + limpar(s))
    }

    private func limpar(_ s: String) -> String {
        s.replacingOccurrences(of: ";", with: ",").replacingOccurrences(of: "\n", with: " ")
    }

    private func hora(_ d: Date) -> String { Formatos.hora.string(from: d) }

    /// Resumo para colar na conversa: rastreadores vistos, trechos entre as marcas, conectados e eventos.
    func resumo() -> String {
        registro.descarregar()
        let agora = Date()
        var t = "RESUMO DO RADAR (iPhone)\n"
        t += "Início \(Formatos.dataHora.string(from: inicio)) · agora \(hora(agora)) · pacotes \(contadorPacotes)\n"
        t += "Bluetooth: \(estadoBluetooth) · registro: \(registro.nomeArquivo)\n\n"
        t += "Marcas: " + (marcas.isEmpty ? "nenhuma" : marcas.map { "\($0.numero) às \(hora($0.hora))" }.joined(separator: " · ")) + "\n\n"

        var pontos: [(Date, String)] = [(inicio, "início")]
        pontos += marcas.map { ($0.hora, "marca \($0.numero)") }
        var cortes: [(de: Date, ate: Date, nome: String)] = []
        for (i, p) in pontos.enumerated() {
            let proximo = i + 1 < pontos.count ? pontos[i + 1] : (agora, "agora")
            cortes.append((p.0, proximo.0, "\(p.1) → \(proximo.1)"))
        }

        let rastreadores = acumulados.values.filter { $0.item.classe.interessante }.sorted { $0.item.primeira < $1.item.primeira }
        t += "RASTREADORES: \(rastreadores.count) identificadores\n\n"
        for a in rastreadores {
            let i = a.item
            let valores = a.amostras.map { $0.1 }
            let media = valores.isEmpty ? 0 : Double(valores.reduce(0, +)) / Double(valores.count)
            t += "\(i.id.uuidString.prefix(8))  \(i.rotulo)\n"
            if !i.tipoPeloStatus.isEmpty {
                t += "   tipo pelo status (palpite): \(i.tipoPeloStatus) · status \(String(format: "%02X", i.status ?? 0)) · bateria \(i.bateria)\n"
            }
            if !i.nome.isEmpty { t += "   nome: \(i.nome)\n" }
            t += "   visto das \(hora(i.primeira)) às \(hora(i.ultima)) · \(i.pacotes) pacotes · RSSI mín \(i.minimo) / média \(Int(media.rounded())) / máx \(i.maximo)\n"
            if !i.estados.isEmpty {
                t += "   estados: " + i.estados.map { "\(hora($0.0)) \($0.1)" }.joined(separator: " · ") + "\n"
            }
            if !i.idChave.isEmpty { t += "   início da chave (modo separado): \(i.idChave)\n" }
            if let c = i.conectavel { t += "   aceita conexão: \(c ? "sim" : "não")\n" }
            for c in cortes {
                let n = a.amostras.filter { $0.0 >= c.de && $0.0 < c.ate }.map { $0.1 }
                guard !n.isEmpty else { continue }
                let m = Double(n.reduce(0, +)) / Double(n.count)
                t += "   \(c.nome): \(n.count) pacotes, RSSI médio \(Int(m.rounded())), máx \(n.max() ?? 0)\n"
            }
            t += "   dados: \(i.dadosHex)\n\n"
        }

        let outros = acumulados.values.filter { !$0.item.classe.interessante && $0.item.maximo >= limiar }
            .sorted { $0.item.maximo > $1.item.maximo }.prefix(25)
        t += "OUTROS COM SINAL FORTE (máx ≥ \(limiar) dBm), os 25 mais fortes\n"
        for a in outros {
            let i = a.item
            t += "   \(i.id.uuidString.prefix(8)) · \(i.rotulo) · máx \(i.maximo) · \(i.pacotes) pacotes · \(i.dadosHex)\n"
        }

        t += "\nCONECTADOS AO IPHONE (última procura)\n"
        if conectados.isEmpty { t += "   nenhum\n" }
        for c in conectados {
            t += "   \(c.nome) · \(c.id.uuidString.prefix(8)) · serviços: \(c.bateuEm.joined(separator: ", ")) · \(c.estado)"
            if let r = c.rssi { t += " · RSSI \(r) (máx \(c.maximo ?? r))" }
            t += "\n"
            for s in c.servicos { t += "      \(s)\n" }
            for l in c.leituras { t += "      \(l)\n" }
        }

        t += "\nEVENTOS (mais novos primeiro)\n"
        t += eventos.prefix(150).joined(separator: "\n")
        return t
    }
}

// MARK: - CoreBluetooth (os retornos chegam na fila principal, que é onde o Radar vive)

extension Radar: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            estadoBluetooth = "ligado"
            comecar()
        case .poweredOff:
            estadoBluetooth = "desligado"
            varrendo = false
        case .unauthorized:
            estadoBluetooth = "sem permissão (Ajustes › Apps › Radar › Bluetooth)"
            varrendo = false
        case .unsupported:
            estadoBluetooth = "sem suporte"
        case .resetting:
            estadoBluetooth = "reiniciando"
        case .unknown:
            estadoBluetooth = "desconhecido"
        @unknown default:
            estadoBluetooth = "estado \(c.state.rawValue)"
        }
        anotarEvento("Bluetooth: \(estadoBluetooth)")
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        guard rssi < 20, rssi > -127 else { return }   // 127 = sem leitura
        contadorPacotes += 1
        let l = Decodificador.ler(advertisementData, nomePeriferico: p.name)
        let agora = Date()
        let id = p.identifier

        let a: Acumulado
        if let existente = acumulados[id] {
            a = existente
        } else {
            if !l.classe.interessante && rssi < limiar && !mostrarTodos { return }   // fraco e sem interesse
            a = Acumulado(item: ItemAnuncio(id: id, primeira: agora, ultima: agora))
            acumulados[id] = a
        }
        perifericos[id] = p
        a.atualizar(l, rssi: rssi, agora: agora)

        // rastreadores: todo pacote vai para o registro; o resto (forte): no máximo um por segundo
        let gravar = l.classe.interessante
            || ((rssi >= limiar || mostrarTodos) && agora.timeIntervalSince(a.ultimoRegistro) >= 1)
        if gravar {
            a.ultimoRegistro = agora
            registro.anotarPacote(agora, id: id, rssi: rssi, l)
        }
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        mudarConectado(p.identifier) { $0.estado = "conectado (medindo)" }
        anotarEvento("Conectado: \(p.name ?? p.identifier.uuidString)")
        p.discoverServices(nil)
        garantirLacoRSSI()
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let motivo = error?.localizedDescription ?? "sem detalhe"
        mudarConectado(p.identifier) { $0.estado = "falhou: \(motivo)" }
        anotarEvento("Falhou ao conectar \(p.name ?? p.identifier.uuidString): \(motivo)")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let motivo = error?.localizedDescription
        mudarConectado(p.identifier) { $0.estado = motivo.map { "caiu: \($0)" } ?? "desconectado pelo app" }
        if seguindoConexao == p.identifier && motivo != nil { seguindoConexao = nil }
        anotarEvento("Desconectado: \(p.name ?? p.identifier.uuidString) \(motivo ?? "")")
    }

    func centralManager(_ c: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for p: CBPeripheral) {
        perifericos[p.identifier] = p
        let tipo: String
        switch event {
        case .peerConnected: tipo = "conectou"
        case .peerDisconnected: tipo = "desconectou"
        @unknown default: tipo = "evento \(event.rawValue)"
        }
        anotarEvento("Sistema \(tipo): \(p.name ?? "(sem nome)") · \(p.identifier.uuidString.prefix(8))")
        registro.anotarLinha("EVENTO_CONEXAO;\(p.identifier.uuidString);\(limpar(p.name ?? ""));\(tipo)")
        if event == .peerConnected, !conectados.contains(where: { $0.id == p.identifier }) {
            conectados.append(ItemConectado(id: p.identifier, nome: p.name ?? "(sem nome)", bateuEm: ["evento de conexão"]))
        }
    }
}

extension Radar: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let r = RSSI.intValue
        guard r < 20, r > -127 else { return }
        mudarConectado(p.identifier) { c in
            c.rssi = r
            c.media = c.media.map { $0 * 0.6 + Double(r) * 0.4 } ?? Double(r)
            c.maximo = max(c.maximo ?? r, r)
        }
        registro.anotarLinha("RSSI_CONEXAO;\(p.identifier.uuidString);\(r)")
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let servicos = p.services ?? []
        mudarConectado(p.identifier) { $0.servicos = servicos.map { "serviço \($0.uuid.uuidString)" } }
        anotarEvento("\(p.name ?? "?"): \(servicos.count) serviços · " + servicos.map { $0.uuid.uuidString }.joined(separator: ", "))
        for s in servicos { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let cs = s.characteristics ?? []
        let texto = cs.map { "\($0.uuid.uuidString)[\(propriedades($0.properties))]" }.joined(separator: " ")
        mudarConectado(p.identifier) { $0.servicos.append("   \(s.uuid.uuidString): \(texto)") }
        registro.anotarLinha("CARACTERISTICAS;\(p.identifier.uuidString);\(s.uuid.uuidString);\(texto)")
        for c in cs where c.properties.contains(.read) && Self.legiveis.contains(c.uuid.uuidString) {
            p.readValue(for: c)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard error == nil, let v = c.value else { return }
        let u = c.uuid.uuidString
        let texto: String
        if u == "2A19", let b = v.first {
            texto = "bateria \(b)%"
        } else if let s = String(data: v, encoding: .utf8), !s.isEmpty {
            texto = "\(nomeCaracteristica(u)): \(s)"
        } else {
            texto = "\(u): " + hexString([UInt8](v))
        }
        mudarConectado(p.identifier) { $0.leituras.append(texto) }
        anotarEvento("\(p.name ?? "?") · \(texto)")
    }

    private func propriedades(_ p: CBCharacteristicProperties) -> String {
        var r: [String] = []
        if p.contains(.read) { r.append("ler") }
        if p.contains(.write) { r.append("escrever") }
        if p.contains(.writeWithoutResponse) { r.append("escrever-sem-resposta") }
        if p.contains(.notify) { r.append("notificar") }
        if p.contains(.indicate) { r.append("indicar") }
        return r.joined(separator: ",")
    }

    private func nomeCaracteristica(_ u: String) -> String {
        switch u {
        case "2A24": return "modelo"
        case "2A26": return "firmware"
        case "2A27": return "hardware"
        case "2A28": return "software"
        case "2A29": return "fabricante"
        default: return u
        }
    }
}
