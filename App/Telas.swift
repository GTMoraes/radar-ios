import SwiftUI
import UIKit

struct InicioView: View {
    @EnvironmentObject var radar: Radar
    @Environment(\.scenePhase) private var fase

    var body: some View {
        TabView {
            NavigationStack { AnunciosView() }
                .tabItem { Label("Anúncios", systemImage: "dot.radiowaves.left.and.right") }
            NavigationStack { ConectadosView() }
                .tabItem { Label("Conectados", systemImage: "link") }
            NavigationStack { EventosView() }
                .tabItem { Label("Eventos", systemImage: "bolt.horizontal") }
            NavigationStack { RegistroView() }
                .tabItem { Label("Registro", systemImage: "doc.text") }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }   // a tela não apaga durante o teste
        .onChange(of: fase) { _, nova in
            if nova == .active {
                UIApplication.shared.isIdleTimerDisabled = true
                radar.voltouAoApp()
            } else if nova == .background {
                radar.registro.descarregar()
            }
        }
    }
}

// MARK: - Anúncios

struct AnunciosView: View {
    @EnvironmentObject var radar: Radar

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Bluetooth")
                    Spacer()
                    Text(radar.estadoBluetooth).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Pacotes recebidos")
                    Spacer()
                    Text("\(radar.totalPacotes)").monospacedDigit().foregroundStyle(.secondary)
                }
                Toggle("Mostrar todos os aparelhos", isOn: $radar.mostrarTodos)
                Stepper("Outros a partir de \(radar.limiar) dBm", value: $radar.limiar, in: -100...(-30), step: 5)
                HStack {
                    Button {
                        radar.marcar()
                    } label: {
                        Label("Marcar \((radar.marcas.last?.numero ?? 0) + 1)", systemImage: "flag")
                    }
                    Spacer()
                    Button {
                        if radar.varrendo { radar.parar() } else { radar.comecar() }
                    } label: {
                        Label(radar.varrendo ? "Pausar" : "Retomar",
                              systemImage: radar.varrendo ? "pause.circle" : "play.circle")
                    }
                }
                .buttonStyle(.borderless)
                if !radar.marcas.isEmpty {
                    Text(radar.marcas.map { "\($0.numero) às \(Formatos.hora.string(from: $0.hora))" }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Rastreadores e aparelhos fortes") {
                if radar.anuncios.isEmpty {
                    Text("Nada por enquanto. Um rastreador conectado ao seu iPhone pode ficar calado (sem anúncio).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(radar.anuncios) { a in
                    NavigationLink {
                        SeguirView(id: a.id)
                    } label: {
                        LinhaAnuncio(a: a)
                    }
                }
            }
        }
        .navigationTitle("Anúncios")
        .telaEscura()
    }
}

struct LinhaAnuncio: View {
    let a: ItemAnuncio

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.rotulo)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(a.classe.interessante ? Tema.acento : Color.primary)
                if !a.estado.isEmpty {
                    Text(a.estado).font(.caption)
                }
                Text(detalhe)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(a.media.rounded()))")
                    .font(.title2.monospacedDigit().weight(.bold))
                Text("dBm").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var detalhe: String {
        var p: [String] = []
        if let s = a.status { p.append(String(format: "status %02X", s)) }
        if !a.bateria.isEmpty { p.append("bateria \(a.bateria)") }
        if !a.tipoPeloStatus.isEmpty { p.append("\(a.tipoPeloStatus) (palpite)") }
        if !a.idChave.isEmpty { p.append("chave \(a.idChave)") }
        if !a.nome.isEmpty { p.append(a.nome) }
        p.append(String(a.id.uuidString.prefix(8)))
        p.append(String(format: "%.1f pac/s", a.pacotesPorSegundo))
        let idade = Int(Date().timeIntervalSince(a.ultima))
        if idade > 2 { p.append("visto há \(idade) s") }
        return p.joined(separator: " · ")
    }
}

// MARK: - Seguir (busca quente/frio por um anúncio)

struct SeguirView: View {
    @EnvironmentObject var radar: Radar
    let id: UUID

    var body: some View {
        let a = radar.seguido?.id == id ? radar.seguido : radar.anuncios.first(where: { $0.id == id })
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    if let a {
                        Text(a.rotulo).font(.headline).multilineTextAlignment(.center)
                        if !a.estado.isEmpty { Text(a.estado).font(.subheadline).foregroundStyle(.secondary) }
                        Text("\(Int(a.media.rounded()))")
                            .font(.system(size: 96, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("dBm · agora \(a.ultimo) · máximo \(a.maximo)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        BarraSinal(valor: a.media)
                        Text(Proximidade.texto(a.media)).font(.title3.weight(.semibold))
                        let idade = Date().timeIntervalSince(a.ultima)
                        if idade > 3 {
                            Text("Sem sinal há \(Int(idade)) s").foregroundStyle(Tema.alerta)
                        }
                    } else {
                        Text("Esse aparelho sumiu da varredura. O endereço dele pode ter mudado: volte e escolha o novo.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))

                VStack(spacing: 4) {
                    Toggle("Som (mais perto, mais rápido)", isOn: $radar.som)
                    Toggle("Vibrar", isOn: $radar.vibrar)
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))

                Button {
                    radar.medirAnunciado(id)
                } label: {
                    Label("Medir pela conexão (aba Conectados)", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)

                Text("Afaste e aproxime o rastreador para ver o número mudar. Quanto mais perto de 0, mais perto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .navigationTitle("Seguir")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { radar.seguindo = id }
        .onDisappear { if radar.seguindo == id { radar.seguindo = nil } }
        .background(Tema.gradiente)
    }
}

// MARK: - Conectados ao iPhone

struct ConectadosView: View {
    @EnvironmentObject var radar: Radar

    var body: some View {
        List {
            Section {
                Button {
                    radar.procurarConectados()
                } label: {
                    Label("Procurar o que está conectado ao iPhone", systemImage: "magnifyingglass")
                }
                Text("Procura, serviço por serviço, os aparelhos que o iPhone mantém conectados (inclusive os que o próprio sistema conectou). Se um rastreador aparecer, toque em Medir sinal e afaste e aproxime ele.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Encontrados") {
                if radar.conectados.isEmpty {
                    Text("Nenhum ainda.").foregroundStyle(.secondary)
                }
                ForEach(radar.conectados) { c in
                    LinhaConectado(c: c)
                }
            }
        }
        .navigationTitle("Conectados")
        .telaEscura()
    }
}

struct LinhaConectado: View {
    @EnvironmentObject var radar: Radar
    let c: ItemConectado
    @State private var aberto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.nome).font(.subheadline.weight(.semibold))
                    Text("\(String(c.id.uuidString.prefix(8))) · \(c.estado)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !c.bateuEm.isEmpty {
                        Text("Serviços: " + c.bateuEm.joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let m = c.media {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(m.rounded()))").font(.title2.monospacedDigit().weight(.bold))
                        Text("dBm").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let m = c.media {
                BarraSinal(valor: m)
                Text(Proximidade.texto(m)).font(.caption)
            }
            HStack {
                if c.estado.hasPrefix("conectado") {
                    Button("Parar") { radar.pararMedicao(c.id) }
                    Spacer()
                    Button(radar.seguindoConexao == c.id ? "Som: ligado" : "Som: desligado") {
                        radar.seguindoConexao = radar.seguindoConexao == c.id ? nil : c.id
                    }
                } else {
                    Button("Medir sinal") { radar.medir(c.id) }
                }
            }
            .buttonStyle(.borderless)
            if !c.servicos.isEmpty || !c.leituras.isEmpty {
                DisclosureGroup("Detalhes", isExpanded: $aberto) {
                    ForEach(Array((c.servicos + c.leituras).enumerated()), id: \.offset) { _, s in
                        Text(s).font(.caption2.monospaced())
                    }
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Eventos

struct EventosView: View {
    @EnvironmentObject var radar: Radar

    var body: some View {
        List {
            Section {
                Button {
                    radar.ouvirConexoes(soRastreadores: false)
                } label: {
                    Label("Ouvir todas as conexões do iPhone", systemImage: "ear")
                }
                Button {
                    radar.ouvirConexoes(soRastreadores: true)
                } label: {
                    Label("Ouvir só serviços de rastreador", systemImage: "line.3.horizontal.decrease.circle")
                }
                Text(radar.ouvindoConexoes.isEmpty ? "Desligado." : "Ouvindo: \(radar.ouvindoConexoes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mais novos primeiro") {
                ForEach(Array(radar.eventos.enumerated()), id: \.offset) { _, e in
                    Text(e).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Eventos")
        .telaEscura()
    }
}

// MARK: - Registro

struct RegistroView: View {
    @EnvironmentObject var radar: Radar
    @State private var texto = ""

    var body: some View {
        List {
            Section("Arquivo") {
                Text(radar.registro.nomeArquivo).font(.callout.monospaced())
                Text("Fica em Arquivos › No Meu iPhone › Radar › Registros.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ShareLink(item: radar.registro.url) {
                    Label("Compartilhar o registro (CSV)", systemImage: "square.and.arrow.up")
                }
                ShareLink(item: texto) {
                    Label("Compartilhar o resumo (texto)", systemImage: "doc.plaintext")
                }
                Button {
                    texto = radar.resumo()
                    UIPasteboard.general.string = texto
                } label: {
                    Label("Copiar o resumo", systemImage: "doc.on.doc")
                }
                Button {
                    texto = radar.resumo()
                } label: {
                    Label("Atualizar o resumo", systemImage: "arrow.clockwise")
                }
            }
            Section("Resumo") {
                Text(texto)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Registro")
        .onAppear { texto = radar.resumo() }
        .telaEscura()
    }
}
