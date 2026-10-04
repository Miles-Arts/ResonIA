import Foundation
import Combine
import SwiftUI
import LiveKit

/// Estados posibles de la cabina interactiva de ResonIA.
public enum CabinaState: Equatable, Sendable {
    /// Desconectado del servidor WebRTC.
    case desconectado

    /// Negociando conexión WebSockets o solicitando credenciales.
    case conectando

    /// Sintonizado y escuchando la sala en vivo.
    case enVivo

    /// Capturando la voz del usuario tras mantener presionado el botón.
    case grabando

    /// Subiendo el archivo de audio al servidor FastAPI.
    case enviandoACabina

    /// Procesando transcripción con faster-whisper y redacción con Ollama.
    case procesandoIA

    /// El Productor IA está transmitiendo la locución por WebRTC.
    case locutorAlAire

    /// Ocurrió un error en la comunicación o procesamiento.
    case error(String)
}

/// Orquestador principal de la experiencia de usuario y máquina de estados de la cabina.
@MainActor
public final class RoomViewModel: ObservableObject {
    // MARK: - Propiedades Publicadas de Configuración

    @Published public var liveKitURL: String = "ws://127.0.0.1:7880"
    @Published public var fastAPIURL: String = "http://127.0.0.1:8000"
    @Published public var token: String = ""
    @Published public var roomName: String = "cabina-resonia"
    @Published public var listenerIdentity: String = "oyente-\(Int.random(in: 1000...9999))"

    // MARK: - Estado de la Interfaz

    @Published public private(set) var currentState: CabinaState = .desconectado
    @Published public private(set) var statusMessage: String = "Desconectado de la cabina"
    @Published public private(set) var lastResponse: AudioProcessResponse?
    @Published public private(set) var errorMessage: String?

    // MARK: - Dependencias

    public let liveKitService: LiveKitService
    public let recorderService: AudioRecorderService
    public let apiService: CabinaAPIService

    private var cancellables = Set<AnyCancellable>()

    /// Inicializador por defecto que instancia los servicios de producción.
    public init() {
        self.liveKitService = LiveKitService()
        self.recorderService = AudioRecorderService()
        self.apiService = .shared

        bindServices()
    }

    /// Inicializador con inyección de dependencias para facilitar testing y mockeo.
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

    /// Configura los observadores de Combine para reaccionar a cambios en los servicios subyacentes.
    private func bindServices() {
        // Propagar actualizaciones del grabador para redibujar medidores y cronómetro en SwiftUI
        recorderService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Monitorear estado de conexión de LiveKit
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
                    self.statusMessage = "Estado de cabina no disponible"
                }
            }
            .store(in: &cancellables)

        // Monitorear actividad del locutor virtual
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

    // MARK: - Gestión de Conexión Automática

    /// Obtiene automáticamente credenciales del backend y se conecta a la sala de LiveKit.
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

    /// Conecta a la sala utilizando credenciales manuales o dispara auto-conexión si no existen.
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

    /// Cierra la sesión activa con la sala de transmisión.
    public func desconectarDeCabina() {
        Task {
            await liveKitService.disconnect()
            self.currentState = .desconectado
            self.statusMessage = "Desconectado"
        }
    }

    // MARK: - Flujo Push-to-Talk

    /// Inicia la grabación del micrófono tras validar los permisos correspondientes.
    public func iniciarGrabacion() {
        Task {
            let granted = await recorderService.requestMicrophonePermission()
            guard granted else {
                self.errorMessage = "Permiso de micrófono denegado en Ajustes del sistema."
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

    /// Detiene la grabación y sube el archivo de audio al backend para su procesamiento.
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

                // Restaurar estado según la conexión activa tras 2 segundos
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.currentState != .locutorAlAire {
                    self.currentState = self.liveKitService.connectionState == .connected ? .enVivo : .desconectado
                    self.statusMessage = self.liveKitService.connectionState == .connected ? "En vivo en \(self.roomName)" : "Listo"
                }

                // Limpieza de archivo temporal
                try? FileManager.default.removeItem(at: audioURL)
            } catch {
                self.currentState = .error(error.localizedDescription)
                self.errorMessage = "Error en Cabina IA: \(error.localizedDescription)"
                self.statusMessage = "Fallo en procesamiento de IA"
            }
        }
    }
}
