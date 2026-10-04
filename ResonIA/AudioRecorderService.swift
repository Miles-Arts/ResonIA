import Foundation
import Combine
import AVFoundation

@MainActor
public final class AudioRecorderService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published public private(set) var isRecording = false
    @Published public private(set) var recordingDuration: TimeInterval = 0
    @Published public private(set) var audioPowerLevel: Float = 0.0

    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var currentFileURL: URL?

    public override init() {
        super.init()
    }

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
        return true
        #endif
    }

    public func startRecording() throws -> URL {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("nota_oyente_\(UUID().uuidString).m4a")
        self.currentFileURL = fileURL

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
            throw NSError(domain: "ResonIA.AudioRecorder", code: -1, userInfo: [NSLocalizedDescriptionKey: "No se pudo iniciar el grabador de audio"])
        }

        self.audioRecorder = recorder
        self.isRecording = true
        self.recordingDuration = 0
        self.audioPowerLevel = 0.0

        startMeteringTimer()
        return fileURL
    }

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

    private func startMeteringTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let recorder = self.audioRecorder, recorder.isRecording else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let normalized = max(0.0, min(1.0, (power + 60.0) / 60.0))
            self.audioPowerLevel = normalized
            self.recordingDuration = recorder.currentTime
        }
        // Usar .common para que el timer no se congele durante el gesto táctil/clic continuo
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    private func stopMeteringTimer() {
        timer?.invalidate()
        timer = nil
        audioPowerLevel = 0.0
    }

    public nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.isRecording = false
            self.stopMeteringTimer()
        }
    }
}
