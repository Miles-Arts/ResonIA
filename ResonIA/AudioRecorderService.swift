import Foundation
import Combine
import AVFoundation

/// Servicio responsable de la captura de notas de voz en alta fidelidad y bajo retardo.
///
/// Implementa `AVAudioRecorder` configurado con compresión AAC a 16 kHz mono,
/// ideal para speech-to-text y minimización del ancho de banda en subida.
@MainActor
public final class AudioRecorderService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    /// Indica si el grabador se encuentra activo capturando audio.
    @Published public private(set) var isRecording = false

    /// Duración acumulada de la grabación actual en segundos.
    @Published public private(set) var recordingDuration: TimeInterval = 0

    /// Nivel de potencia de audio normalizado (0.0 a 1.0) para alimentar animaciones de volumen.
    @Published public private(set) var audioPowerLevel: Float = 0.0

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileURL: URL?

    public override init() {
        super.init()
    }

    /// Solicita de forma asíncrona los permisos del sistema operativo para acceder al micrófono.
    ///
    /// - Returns: `true` si el usuario concedió el permiso o `false` en caso contrario.
    public func requestMicrophonePermission() async -> Bool {
        #if os(iOS)
        if #available(iOS 17.0, *) {
            return await AVAudioApplication.requestRecordPermission()
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        #else
        // En macOS los permisos son gestionados automáticamente o mediante entitlements
        return true
        #endif
    }

    /// Configura la sesión de audio y arranca una nueva grabación en el directorio temporal.
    ///
    /// - Returns: La `URL` del archivo `.m4a` donde se almacenará la pista de voz.
    /// - Throws: Errores de inicialización de `AVAudioSession` o `AVAudioRecorder`.
    public func startRecording() throws -> URL {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("nota_oyente_\(UUID().uuidString).m4a")
        self.currentFileURL = fileURL

        // Configuración óptima para reconocimiento de voz: 16 kHz, 1 canal mono, AAC
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 32000
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        guard recorder.record() else {
            throw NSError(
                domain: "ResonIA.AudioRecorder",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No fue posible inicializar el grabador de audio del sistema."]
            )
        }

        self.audioRecorder = recorder
        self.isRecording = true
        self.recordingDuration = 0
        self.audioPowerLevel = 0.0

        startMeteringTimer()
        return fileURL
    }

    /// Detiene la grabación actual y libera los recursos del grabador.
    ///
    /// - Returns: La `URL` final del archivo de audio grabado si existió grabación válida.
    public func stopRecording() -> URL? {
        guard isRecording, let recorder = audioRecorder else {
            return nil
        }

        recorder.stop()
        stopMeteringTimer()

        self.isRecording = false
        let recordedURL = self.currentFileURL
        self.audioRecorder = nil

        return recordedURL
    }

    /// Inicia el temporizador de medición de potencia en el RunLoop `.common`
    /// para evitar que gestos táctiles continuos congelen el contador.
    private func startMeteringTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()

            let power = recorder.averagePower(forChannel: 0)
            // Normalizar dB (-60 dB a 0 dB) al rango [0.0, 1.0]
            let normalized = max(0.0, min(1.0, (power + 60.0) / 60.0))
            self.audioPowerLevel = normalized
            self.recordingDuration = recorder.currentTime
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    /// Cancela y libera el temporizador de medición.
    private func stopMeteringTimer() {
        timer?.invalidate()
        timer = nil
        audioPowerLevel = 0.0
    }

    // MARK: - AVAudioRecorderDelegate

    public nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            self.stopMeteringTimer()
        }
    }
}
