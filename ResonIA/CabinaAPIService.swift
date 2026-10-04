import Foundation

/// Estructura de respuesta devuelta por el endpoint `GET /token`.
public struct TokenResponse: Codable, Sendable {
    /// Estado del servicio.
    public let status: String

    /// Nombre de la sala WebRTC asignada.
    public let room: String

    /// Identidad registrada en la sesión de LiveKit.
    public let identity: String

    /// Token JWT firmado para autenticación en la sala.
    public let token: String

    /// URL del servidor LiveKit WebRTC.
    public let serverUrl: String

    enum CodingKeys: String, CodingKey {
        case status
        case room
        case identity
        case token
        case serverUrl = "server_url"
    }
}

/// Cliente de red asíncrono para la comunicación HTTP con el backend de Cabina FastAPI.
public final class CabinaAPIService: Sendable {
    /// Instancia compartida (Singleton) del servicio.
    public static let shared = CabinaAPIService()

    private let defaultBaseURL = "http://127.0.0.1:8000"

    public init() {}

    /// Solicita un token JWT firmado al backend para autenticar la conexión WebRTC.
    ///
    /// - Parameters:
    ///   - identity: Identificador único asignado al oyente.
    ///   - baseURLString: URL base opcional del servidor (por defecto http://127.0.0.1:8000).
    /// - Returns: Instancia de `TokenResponse` con el JWT y la sala.
    /// - Throws: `URLError` si la URL es inválida o el servidor responde con error.
    public func obtenerToken(
        identity: String,
        baseURLString: String? = nil
    ) async throws -> TokenResponse {
        let host = baseURLString ?? defaultBaseURL
        var components = URLComponents(string: "\(host)/token")
        components?.queryItems = [
            URLQueryItem(name: "identity", value: identity),
            URLQueryItem(name: "name", value: "Oyente iOS")
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// Sube una nota de voz mediante multipart/form-data al backend para su procesamiento por IA.
    ///
    /// - Parameters:
    ///   - fileURL: Ubicación en disco del archivo de audio grabado (.m4a / .wav).
    ///   - baseURLString: URL base opcional del servidor FastAPI.
    /// - Returns: Objeto `AudioProcessResponse` con la transcripción y el resumen moderado.
    /// - Throws: Error de red o decodificación si el procesamiento falla.
    public func procesarAudio(
        fileURL: URL,
        baseURLString: String? = nil
    ) async throws -> AudioProcessResponse {
        let host = baseURLString ?? defaultBaseURL
        guard let url = URL(string: "\(host)/procesar-audio") else {
            throw URLError(.badURL)
        }

        let audioData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60.0

        var body = Data()

        // Construcción segura del cuerpo multipart sin 'force unwrap'
        func append(_ string: String) {
            if let stringData = string.data(using: .utf8) {
                body.append(stringData)
            }
        }

        let sanitizedFilename = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(sanitizedFilename)\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let serverError = String(data: data, encoding: .utf8) ?? "Error HTTP \(httpResponse.statusCode)"
            throw NSError(
                domain: "ResonIA.CabinaAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: serverError]
            )
        }

        return try JSONDecoder().decode(AudioProcessResponse.self, from: data)
    }

    /// Comprueba la conectividad y disponibilidad del backend.
    ///
    /// - Parameter baseURLString: URL base del servidor a inspeccionar.
    /// - Returns: `true` si el servidor responde con código 200, `false` en caso contrario.
    public func verificarSalud(baseURLString: String? = nil) async -> Bool {
        let host = baseURLString ?? defaultBaseURL
        guard let url = URL(string: "\(host)/docs") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3.0
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
