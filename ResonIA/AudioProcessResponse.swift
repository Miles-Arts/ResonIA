import Foundation

public struct AudioProcessResponse: Codable, Sendable {
    public let status: String
    public let transcripcionOriginal: String?
    public let resumenLocutor: String?
    public let aprobado: Bool?
    public let audioGenerado: Bool?
    public let archivoAudio: String?

    enum CodingKeys: String, CodingKey {
        case status
        case transcripcionOriginal = "transcripcion_original"
        case resumenLocutor = "resumen_locutor"
        case aprobado
        case audioGenerado = "audio_generado"
        case archivoAudio = "archivo_audio"
    }

    public init(
        status: String,
        transcripcionOriginal: String? = nil,
        resumenLocutor: String? = nil,
        aprobado: Bool? = nil,
        audioGenerado: Bool? = nil,
        archivoAudio: String? = nil
    ) {
        self.status = status
        self.transcripcionOriginal = transcripcionOriginal
        self.resumenLocutor = resumenLocutor
        self.aprobado = aprobado
        self.audioGenerado = audioGenerado
        self.archivoAudio = archivoAudio
    }
}
