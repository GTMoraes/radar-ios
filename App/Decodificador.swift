import Foundation
import CoreBluetooth

/// O que o pacote é. Quanto maior, mais interessante para o teste.
enum Classe: Int, Comparable {
    case outro = 0, appleOutro, tile, smartTag, apple07, googleFindHub, dult, findMy

    static func < (a: Classe, b: Classe) -> Bool { a.rawValue < b.rawValue }

    var interessante: Bool { self >= .tile }
}

/// Um pacote de anúncio já decodificado.
struct Leitura {
    var classe: Classe = .outro
    var rotulo = ""
    var estado = ""
    var status: UInt8?
    var bateria = ""
    var tipoPeloStatus = ""
    /// no modo separado o pacote leva 22 bytes da chave; os 4 primeiros servem de "nome" do rastreador naquele dia
    var idChave = ""
    var nome = ""
    var dadosHex = ""
    var conectavel: Bool?
}

/// Lê os anúncios que o iOS entrega. Diferente do PC, o iPhone não mostra o endereço Bluetooth, então no modo
/// "perto do dono" (em que a chave vai quase toda no endereço) não há como saber qual rastreador é qual.
enum Decodificador {
    static func ler(_ dados: [String: Any], nomePeriferico: String?) -> Leitura {
        var l = Leitura()
        l.nome = (dados[CBAdvertisementDataLocalNameKey] as? String) ?? nomePeriferico ?? ""
        if let c = dados[CBAdvertisementDataIsConnectable] as? NSNumber { l.conectavel = c.boolValue }
        var partes: [String] = []

        // dados de fabricante: os 2 primeiros bytes são o código da empresa (0x004C = Apple)
        if let md = dados[CBAdvertisementDataManufacturerDataKey] as? Data, md.count >= 2 {
            let b = [UInt8](md)
            let empresa = UInt16(b[0]) | (UInt16(b[1]) << 8)
            let resto = Array(b.dropFirst(2))
            partes.append(String(format: "M%04X:", empresa) + hexString(resto))
            if empresa == 0x004C {
                lerApple(&l, resto)
            } else if l.rotulo.isEmpty {
                l.rotulo = String(format: "fabricante 0x%04X", empresa)
            }
        }

        // dados de serviço (o iOS já tira o UUID do começo)
        if let sd = dados[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, d) in sd {
                let b = [UInt8](d)
                let u = uuid.uuidString.uppercased()
                partes.append("S\(u):" + hexString(b))
                if u == "FCB2", b.count >= 2 {
                    // padrão IETF de rastreadores (DULT): rede (0x01 Apple, 0x02 Google) e o bit "perto do dono"
                    let rede: String
                    switch b[0] {
                    case 0x01: rede = "Apple"
                    case 0x02: rede = "Google"
                    default: rede = String(format: "0x%02X", b[0])
                    }
                    let estado = (b[1] & 0x01) == 1 ? "perto do dono" : "separado"
                    if l.classe == .findMy {
                        l.rotulo += " + DULT (\(rede), \(estado))"
                    } else {
                        l.classe = .dult
                        l.rotulo = "DULT (rede \(rede))"
                        l.estado = estado
                    }
                } else if u == "FEAA", let f = b.first, f == 0x40 || f == 0x41 {
                    if l.classe < .googleFindHub {
                        l.classe = .googleFindHub
                        l.rotulo = "Google Find Hub"
                        l.estado = f == 0x41 ? "anti-rastreio" : "normal"
                    }
                } else if u == "FD5A" {
                    if l.classe < .smartTag { l.classe = .smartTag; l.rotulo = "Samsung SmartTag" }
                } else if u == "FEED" || u == "FEEC" {
                    if l.classe < .tile { l.classe = .tile; l.rotulo = "Tile" }
                }
            }
        }

        if let us = dados[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            partes += us.map { "U" + $0.uuidString }
        }
        if let us = dados[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            partes += us.map { "O" + $0.uuidString }
        }

        l.dadosHex = partes.joined(separator: " ")
        if l.rotulo.isEmpty { l.rotulo = l.nome.isEmpty ? "(sem dados)" : "\"\(l.nome)\"" }
        return l
    }

    /// Blocos tipo, tamanho, conteúdo. Tipo 0x12 = Find My. Tamanho 25 = separado, tamanho 2 = perto do dono.
    private static func lerApple(_ l: inout Leitura, _ b: [UInt8]) {
        var i = 0
        var achou = false
        while i + 1 < b.count {
            let tipo = b[i]
            var tam = Int(b[i + 1])
            let p = i + 2
            if p + tam > b.count { tam = b.count - p }   // pacote cortado: aproveita o que tem

            if tipo == 0x12 {
                achou = true
                l.classe = .findMy
                l.rotulo = "Find My"
                if tam >= 25 {
                    l.estado = "separado"
                    l.status = b[p]
                    l.idChave = hexString(Array(b[(p + 1)..<(p + 5)]))
                } else if tam == 2 {
                    l.estado = "perto do dono"
                    l.status = b[p]
                } else {
                    l.estado = "formato tam=\(tam)"
                    if tam >= 1 { l.status = b[p] }
                }
                if let s = l.status {
                    switch (s >> 6) & 0x03 {
                    case 0: l.bateria = "cheia"
                    case 1: l.bateria = "média"
                    case 2: l.bateria = "baixa"
                    default: l.bateria = "crítica"
                    }
                    switch (s >> 4) & 0x03 {
                    case 0: l.tipoPeloStatus = "aparelho Apple"
                    case 1: l.tipoPeloStatus = "AirTag"
                    case 2: l.tipoPeloStatus = "acessório Find My"
                    default: l.tipoPeloStatus = "AirPods"
                    }
                }
            } else if tipo == 0x07 && !achou {
                if l.classe < .apple07 { l.classe = .apple07; l.rotulo = "Apple 0x07 (pareamento)" }
            } else if !achou && l.classe == .outro {
                l.classe = .appleOutro
                l.rotulo = String(format: "Apple 0x%02X", tipo)
            }

            if tam <= 0 { break }
            i = p + tam
        }
    }
}
