import Foundation
import Combine
import SwiftUI
import LiveKit

public enum CabinaState: Equatable, Sendable {
    case desconectado
    case conectando
    case enVivo
    case grabando
    case enviandoACabina
    case procesandoIA
    case locutorAlAire
    case error(String)
}

@MainActor
public final class RoomViewModel: ObservableObject {
    @Published public var liveKitURL: String = "ws://127.0.0.1:7880"
    @Published public var fastAPIURL: String = "http://127.0.0.1:8000"
    @Published public var token: String = ""
    @Published public var roomName: String = "cabina-resonia"
    @Published public var listenerIdentity: String = "oyente-\(Int.random(in: 1000...9999))"

    @Published public private(set) var currentState: CabinaState = .desconectado
    @Published public private(set) var statusMessage: String = "Desconectado de la cabina"
    @Published public private(set) var lastResponse: AudioProcessResponse?
    @Published public private(set) var errorMessage: String?

    public let liveKitService: LiveKitService
    public let recorderService: AudioRecorderService
    public let apiService: CabinaAPIService

    private var cancellables = Set<AnyCancellable>()

    public init() {
        self.liveKitService = LiveKitService()
        self.recorderService = AudioRecorderService()
        self.apiService = .shared

        bindServices()
    }

    public init(
        liveKitService: LiveKitService,
        recorderService: AudioRecorderService,
        apiService: CabinaAPIService
    ) {
        self.liveKitService = liveKitService
        self.recorderService = recorderService
        self.apiService = apiService

        bindServices()
    }

    private func bindServices() {
        // Observar estado de conexión de LiveKit
        liveKitService.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .connected:
                    if self.currentState != .grabando && self.currentState != .enviandoACabina && self.currentState != .procesandoIA {
                        self.currentState = .enVivo
                        self.statusMessage = "En vivo en \(self.roomName)"
                    }
                case .connecting, .reconnecting:
                    self.currentState = .conectando
                    self.statusMessage = "Sintonizando transmisión WebRTC..."
                case .disconnected:
                    self.currentState = .desconectado
                    self.statusMessage = "Desconectado de la cabina"
                @unknown default:
                    self.currentState = .desconectado
                    self.statusMessage = "Estado desconocido"
                }
            }
            .store(in: &cancellables)

        // Observar actividad del locutor IA
        liveKitService.$isLocutorSpeaking
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isSpeaking in
                guard let self = self else { return }
                if isSpeaking && self.liveKitService.connectionState == .connected {
                    self.currentState = .locutorAlAire
                    self.statusMessage = "🎙️ Productor IA transmitiendo al aire..."
                } else if self.currentState == .locutorAlAire {
                    self.currentState = .enVivo
                    self.statusMessage = "En vivo en \(self.roomName)"
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Conexión Automática con Backend

    public func conectarAutomaticamente() {
        currentState = .conectando
        statusMessage = "Solicitando credenciales a cabina..."
        errorMessage = nil

        Task {
            do {
                let tokenInfo = try await apiService.obtenerToken(
                    identity: listenerIdentity,
                    baseURLString: fastAPIURL
                )

                self.token = tokenInfo.token
                self.roomName = tokenInfo.room
                self.liveKitURL = tokenInfo.serverUrl
                self.statusMessage = "Conectando a cabina en vivo..."

                try await liveKitService.connect(url: self.liveKitURL, token: self.token)
                self.currentState = .enVivo
                self.statusMessage = "En vivo en \(self.roomName)"
            } catch {
                self.currentState = .error(error.localizedDescription)
                self.errorMessage = "Error al enlazar con la cabina: \(error.localizedDescription)"
                self.statusMessage = "Fallo de conexión"
            }
        }
    }

    public func conectarACabina() {
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conectarAutomaticamente()
            return
        }

        currentState = .conectando
        statusMessage = "Conectando a \(liveKitURL)..."
        errorMessage = nil

        Task {
            do {
                try await liveKitService.connect(url: liveKitURL, token: token)
                self.currentState = .enVivo
                self.statusMessage = "Conectado a \(roomName)"
            } catch {
                self.currentState = .error(error.localizedDescription)
                self.errorMessage = "Error de conexión WebRTC: \(error.localizedDescription)"
                self.statusMessage = "Error al conectar"
            }
        }
    }

    public func desconectarDeCabina() {
        Task {
            await liveKitService.disconnect()
            self.currentState = .desconectado
            self.statusMessage = "Desconectado"
        }
    }

    // MARK: - Grabación Push-to-Talk y Envío a Cabina IA

    public func iniciarGrabacion() {
        Task {
            let granted = await recorderService.requestMicrophonePermission()
            guard granted else {
                self.errorMessage = "Permiso de micrófono denegado en Ajustes de iOS."
                return
            }

            do {
                _ = try self.recorderService.startRecording()
                self.currentState = .grabando
                self.statusMessage = "Grabando pregunta para la cabina..."
                self.errorMessage = nil
            } catch {
                self.errorMessage = "Error al iniciar grabación: \(error.localizedDescription)"
            }
        }
    }

    public func soltarYEnviarGrabacion() {
        guard let audioURL = recorderService.stopRecording() else {
            if currentState == .grabando {
                currentState = liveKitService.connectionState == .connected ? .enVivo : .desconectado
                statusMessage = "Grabación cancelada"
            }
            return
        }

        currentState = .enviandoACabina
        statusMessage = "Enviando nota a la cabina FastAPI..."

        Task {
            do {
                self.currentState = .procesandoIA
                self.statusMessage = "Whisper transcribiendo y Ollama resumiendo..."

                let response = try await apiService.procesarAudio(
                    fileURL: audioURL,
                    baseURLString: fastAPIURL
                )

                self.lastResponse = response

                if response.aprobado == true {
                    self.statusMessage = "Nota aprobada. Productor IA saldrá al aire..."
                } else {
                    self.statusMessage = "Nota filtrada por moderación."
                }

                // Restaurar estado según conexión LiveKit tras breve pausa
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.currentState != .locutorAlAire {
                    self.currentState = self.liveKitService.connectionState == .connected ? .enVivo : .desconectado
                    self.statusMessage = self.liveKitService.connectionState == .connected ? "En vivo en \(self.roomName)" : "Listo"
                }

                // Eliminar archivo temporal
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                self.currentState = .error(error.localizedDescription)
                self.errorMessage = "Error en Cabina IA: \(error.localizedDescription)"
                self.statusMessage = "Fallo en procesamiento de IA"
            }
        }
    }
}
