import AVFoundation

/// Captures microphone audio, writes it to an AAC (.m4a) file and hands every buffer to a
/// transcriber. Buffers arrive on an audio thread; state shared with it is guarded by `lock`.
final class AudioCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noMicrophone

        var errorDescription: String? {
            "No microphone is available."
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()

    // Guarded by `lock`.
    private let converter = BufferConverter()
    private var recordingFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var framesWritten: AVAudioFramePosition = 0
    private var currentLevel: Float = 0
    private var writeFailed = false
    private var wantsRunning = false

    // Main thread only.
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?

    /// Microphone level from 0 (silence) to 1 (loud).
    var level: Float {
        lock.withLock { currentLevel }
    }

    /// Seconds of audio written so far (pauses excluded).
    var duration: TimeInterval {
        lock.withLock {
            guard let recordingFormat else { return 0 }
            return Double(framesWritten) / recordingFormat.sampleRate
        }
    }

    var hasWriteError: Bool {
        lock.withLock { writeFailed }
    }

    /// Call once the audio session is active. Returns the mono format buffers will be delivered in.
    func prepare() throws -> AVAudioFormat {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputFormat.sampleRate, channels: 1, interleaved: false)
        else {
            throw CaptureError.noMicrophone
        }
        lock.withLock { recordingFormat = mono }
        return mono
    }

    func start(fileURL: URL, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard let format = lock.withLock({ recordingFormat }) else { throw CaptureError.noMicrophone }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            self.file = file
            self.bufferHandler = onBuffer
            self.framesWritten = 0
            self.wantsRunning = true
        }
        installTap()
        observeConfigurationChanges()
        engine.prepare()
        try engine.start()
    }

    func pause() {
        lock.withLock { wantsRunning = false }
        engine.pause()
    }

    func resume() throws {
        lock.withLock { wantsRunning = true }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Stops capturing and closes the file, which finalises the .m4a so it can be played.
    func stop() {
        lock.withLock { wantsRunning = false }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        lock.withLock {
            file = nil
            bufferHandler = nil
        }
    }

    // MARK: Private

    private func installTap() {
        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        tapInstalled = true
    }

    /// Plugging in headphones, a call ending, etc. stops the engine and may change the input
    /// format. Re-install the tap for the new format and carry on.
    private func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        installTap()
        guard lock.withLock({ wantsRunning }) else { return }
        engine.prepare()
        try? engine.start()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let mono = writeLocked(buffer)
        let handler = bufferHandler
        lock.unlock()
        if let mono {
            handler?(mono)
        }
    }

    /// Must be called with `lock` held.
    private func writeLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let format = recordingFormat, let file,
              let mono = try? converter.convert(buffer, to: format) else { return nil }
        do {
            try file.write(from: mono)
        } catch {
            writeFailed = true
        }
        framesWritten += AVAudioFramePosition(mono.frameLength)
        currentLevel = Self.normalizedLevel(of: mono)
        return mono
    }

    private static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = channels[0]
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (decibels + 55) / 55))
    }
}
