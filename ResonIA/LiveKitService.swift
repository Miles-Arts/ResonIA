import Foundation
import Combine
import LiveKit

/// Servicio de transporte de audio WebRTC en tiempo real basado en el SDK oficial de LiveKit.
///
/// Gestiona la conexión a la sala virtual, la suscripción a pistas de audio y la
/// detección de voz del bot Productor IA al aire.
@MainActor
public final class LiveKitService: ObservableObject, RoomDelegate {
    /// Estado actual de la conexión WebRTC (.connected, .connecting, .disconnected, etc.).
    @Published public private(set) var connectionState: ConnectionState = .disconnected

    /// Indica si el Productor IA se encuentra transmitiendo activamente voz por el canal WebRTC.
    @Published public private(set) var isLocutorSpeaking: Bool = false

    /// Número total de participantes presentes en la cabina (incluyendo al usuario local).
    @Published public private(set) var participantCount: Int = 0

    /// Lista de participantes remotos conectados en la sala.
    @Published public private(set) var remoteParticipants: [RemoteParticipant] = []

    /// Instancia central de la sala WebRTC de LiveKit.
    public let room: Room

    public init() {
        self.room = Room()
        self.room.add(delegate: self)
    }

    /// Establece la conexión con el servidor LiveKit utilizando la URL y el token JWT provistos.
    ///
    /// - Parameters:
    ///   - url: Dirección WebSockets del servidor LiveKit (ej. `ws://127.0.0.1:7880`).
    ///   - token: Token JWT con los permisos de acceso a la sala.
    public func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
        self.connectionState = room.connectionState
        self.updateParticipants()
    }

    /// Desconecta al cliente de la sala y reinicia los estados de telemetría.
    public func disconnect() async {
        await room.disconnect()
        self.connectionState = .disconnected
        self.isLocutorSpeaking = false
        self.updateParticipants()
    }

    /// Actualiza la lista de participantes remotos y el recuento total para la interfaz de usuario.
    private func updateParticipants() {
        self.remoteParticipants = Array(room.remoteParticipants.values)
        self.participantCount = room.remoteParticipants.count + (room.connectionState == .connected ? 1 : 0)
    }

    // MARK: - RoomDelegate

    public nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            self.connectionState = connectionState
            self.updateParticipants()
        }
    }

    public nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.updateParticipants()
        }
    }

    public nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.updateParticipants()
        }
    }

    public nonisolated func room(_ room: Room, didUpdateSpeakers speakers: [Participant]) {
        Task { @MainActor in
            // Identificar si alguno de los oradores activos corresponde al Productor IA
            let speaking = speakers.contains { participant in
                let idStr = participant.identity?.stringValue ?? ""
                return idStr.localizedCaseInsensitiveContains("productor") || idStr.localizedCaseInsensitiveContains("ia")
            }
            self.isLocutorSpeaking = speaking
        }
    }
}
