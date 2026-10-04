import Foundation
import Combine
import LiveKit

@MainActor
public final class LiveKitService: ObservableObject, RoomDelegate {
    @Published public private(set) var connectionState: ConnectionState = .disconnected
    @Published public private(set) var isLocutorSpeaking: Bool = false
    @Published public private(set) var participantCount: Int = 0
    @Published public private(set) var remoteParticipants: [RemoteParticipant] = []

    public let room: Room

    public init() {
        self.room = Room()
        self.room.add(delegate: self)
    }

    public func connect(url: String, token: String) async throws {
        try await room.connect(url: url, token: token)
        self.connectionState = room.connectionState
        self.updateParticipants()
    }

    public func disconnect() async {
        await room.disconnect()
        self.connectionState = .disconnected
        self.isLocutorSpeaking = false
        self.updateParticipants()
    }

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
            let speaking = speakers.contains { participant in
                let idStr = participant.identity?.stringValue ?? ""
                return idStr.lowercased().contains("productor") || idStr.lowercased().contains("ia")
            }
            self.isLocutorSpeaking = speaking
        }
    }
}
