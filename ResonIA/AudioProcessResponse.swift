import Foundation

/// Modelo de datos que encapsula la respuesta del servidor FastAPI tras procesar una nota de voz.
public struct AudioProcessResponse: Codable, Sendable {
    /// Estado general de la operación ('success' o 'error').
    public let status: String

    /// Transcripción literal obtenida mediante faster-whisper.
    public let transcripcionOriginal: String?

    /// Frase redactada con estilo radial o 'RECHAZADO' si no pasó la moderación.
    public let resumenLocutor: String?

    /// Indica si el mensaje fue admitido por las políticas editoriales y de convivencia de la cabina.
    public let aprobado: Bool?

    /// Indica si el archivo de audio con la voz del locutor fue generado exitosamente.
    public let audioGenerado: Bool?

    /// Nombre del archivo de audio resultante en el servidor (ej. 'respuesta.wav').
    public let archivoAudio: String?

    enum CodingKeys: String, CodingKey {
        case status
        case transcripcionOriginal = "transcripcion_original"
        case resumenLocutor = "resumen_locutor"
        case aprobado
        case audioGenerado = "audio_generado"
        case archivoAudio = "archivo_audio"
    }

    /// Inicializador principal para pruebas unitarias y decodificación.
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
