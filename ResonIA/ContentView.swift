import SwiftUI
import LiveKit

public struct ContentView: View {
    @StateObject private var viewModel = RoomViewModel()
    @State private var showingSettings = false

    public var body: some View {
        NavigationStack {
            ZStack {
                // Fondo temático de cabina radial nocturna
                Color(red: 0.05, green: 0.06, blue: 0.10)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    cabeceraCabina

                    if viewModel.liveKitService.isLocutorSpeaking {
                        alAireBanner
                            .transition(.scale.combined(with: .opacity))
                    }

                    tarjetaResumenIA

                    Spacer()

                    // Visualizador de audio mientras graba (contador de tiempo y barra de decibelios)
                    if viewModel.currentState == .grabando {
                        visualizadorAudio
                            .transition(.opacity)
                    }

                    // Botón Walkie-Talkie / Push-to-Talk
                    botonPushToTalk

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            .navigationTitle("ResonIA")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSettings.toggle()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.cyan)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                configuracionSheet
            }
            .onAppear {
                // Auto-sintonizar la cabina al abrir la app
                if viewModel.liveKitService.connectionState == .disconnected {
                    viewModel.conectarAutomaticamente()
                }
            }
        }
    }

    // MARK: - Subvistas

    private var cabeceraCabina: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.roomName)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)

                HStack(spacing: 6) {
                    Circle()
                        .fill(colorParaEstado)
                        .frame(width: 10, height: 10)
                        .shadow(color: colorParaEstado, radius: 4)

                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            if viewModel.liveKitService.connectionState == .disconnected {
                Button("Sintonizar") {
                    viewModel.conectarAutomaticamente()
                }
                .font(.caption.bold())
                .foregroundColor(.cyan)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.cyan.opacity(0.15))
                .clipShape(Capsule())
            } else {
                // Indicador de oyentes conectados
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.caption)
                    Text("\(viewModel.liveKitService.participantCount)")
                        .font(.caption.bold())
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }
        }
        .padding()
        .background(Color(red: 0.10, green: 0.12, blue: 0.18))
        .cornerRadius(16)
    }

    private var alAireBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .overlay(
                    Circle()
                        .stroke(Color.red.opacity(0.5), lineWidth: 4)
                        .scaleEffect(1.4)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("AL AIRE • PRODUCTOR IA")
                    .font(.caption.bold())
                    .foregroundColor(.red)

                Text("Transmitiendo locución sintetizada")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }

            Spacer()

            Image(systemName: "waveform")
                .font(.title3)
                .foregroundColor(.red)
                .symbolEffect(.variableColor.iterative.reversing)
        }
        .padding()
        .background(Color.red.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(14)
    }

    private var tarjetaResumenIA: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.cyan)
                Text("Última Intervención en Cabina")
                    .font(.caption.bold())
                    .foregroundColor(.cyan)
                Spacer()

                if let aprobado = viewModel.lastResponse?.aprobado {
                    Text(aprobado ? "APROBADO" : "MODERADO")
                        .font(.system(size: 9, weight: .black))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(aprobado ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                        .foregroundColor(aprobado ? .green : .red)
                        .clipShape(Capsule())
                }
            }

            if let response = viewModel.lastResponse {
                if let resumen = response.resumenLocutor, !resumen.isEmpty {
                    Text(resumen)
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.vertical, 2)
                }

                if let original = response.transcripcionOriginal, !original.isEmpty {
                    Text("Oyente: \"\(original)\"")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .italic()
                }
            } else {
                Text("Mantén presionado el botón inferior para enviar tu pregunta a la cabina inteligente.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.08, green: 0.10, blue: 0.15))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var visualizadorAudio: some View {
        HStack(spacing: 8) {
            Image(systemName: "record.circle")
                .foregroundColor(.red)

            Text(String(format: "00:%02d", Int(viewModel.recorderService.recordingDuration)))
                .font(.system(.body, design: .monospaced).bold())
                .foregroundColor(.white)

            // Barra reactiva al volumen de voz
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(Color.red)
                        .frame(width: max(4, proxy.size.width * CGFloat(viewModel.recorderService.audioPowerLevel)))
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal)
    }

    private var botonPushToTalk: some View {
        VStack(spacing: 12) {
            ZStack {
                // Círculo exterior pulsante al grabar
                Circle()
                    .fill(viewModel.currentState == .grabando ? Color.red.opacity(0.25) : Color.cyan.opacity(0.12))
                    .frame(width: 140, height: 140)
                    .scaleEffect(viewModel.currentState == .grabando ? (1.0 + CGFloat(viewModel.recorderService.audioPowerLevel) * 0.35) : 1.0)
                    .animation(.easeOut(duration: 0.1), value: viewModel.recorderService.audioPowerLevel)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: viewModel.currentState == .grabando
                                ? [Color.red, Color(red: 0.8, green: 0.1, blue: 0.1)]
                                : [Color.cyan, Color(red: 0.1, green: 0.4, blue: 0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .shadow(
                        color: viewModel.currentState == .grabando ? Color.red.opacity(0.5) : Color.cyan.opacity(0.3),
                        radius: 12
                    )

                Image(systemName: viewModel.currentState == .grabando ? "waveform.and.mic" : "mic.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white)
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if viewModel.currentState != .grabando && viewModel.currentState != .enviandoACabina && viewModel.currentState != .procesandoIA {
                            viewModel.iniciarGrabacion()
                        }
                    }
                    .onEnded { _ in
                        if viewModel.currentState == .grabando {
                            viewModel.soltarYEnviarGrabacion()
                        }
                    }
            )

            Text(viewModel.currentState == .grabando ? "Suelta para enviar a cabina" : "Mantén presionado para hablar")
                .font(.footnote.bold())
                .foregroundColor(viewModel.currentState == .grabando ? .red : .gray)
        }
    }

    private var configuracionSheet: some View {
        NavigationStack {
            Form {
                Section("Conexión LiveKit (Audio en Vivo)") {
                    TextField("URL WebSockets", text: $viewModel.liveKitURL)
                        .autocorrectionDisabled()

                    SecureField("Token JWT de Acceso", text: $viewModel.token)
                        .autocorrectionDisabled()

                    if viewModel.liveKitService.connectionState == .connected {
                        Button("Desconectar de Sala", role: .destructive) {
                            viewModel.desconectarDeCabina()
                        }
                    } else {
                        Button("Conectar a Cabina") {
                            viewModel.conectarACabina()
                        }
                    }
                }

                Section("Servidor de IA (FastAPI)") {
                    TextField("Endpoint FastAPI", text: $viewModel.fastAPIURL)
                        .autocorrectionDisabled()

                    Button("Re-sintonizar con Servidor") {
                        viewModel.conectarAutomaticamente()
                    }
                }

                Section("Información del Oyente") {
                    LabeledContent("Identidad", value: viewModel.listenerIdentity)
                    LabeledContent("Sala", value: viewModel.roomName)
                }
            }
            .navigationTitle("Ajustes de Cabina")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") {
                        showingSettings = false
                    }
                }
            }
        }
    }

    private var colorParaEstado: Color {
        switch viewModel.currentState {
        case .enVivo:
            return .green
        case .locutorAlAire:
            return .red
        case .grabando:
            return .red
        case .conectando, .procesandoIA, .enviandoACabina:
            return .orange
        case .desconectado, .error:
            return .gray
        }
    }
}

#Preview {
    ContentView()
}
