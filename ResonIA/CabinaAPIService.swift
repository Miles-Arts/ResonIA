import Foundation

public final class CabinaAPIService: Sendable {
    public static let shared = CabinaAPIService()

    private let defaultBaseURL = "http://127.0.0.1:8000"

    public init() {}

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

        // Campo 'file' esperado por FastAPI: UploadFile = File(...)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

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

        let decoder = JSONDecoder()
        return try decoder.decode(AudioProcessResponse.self, from: data)
    }

    /// Comprueba la conectividad básica con el backend FastAPI
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
