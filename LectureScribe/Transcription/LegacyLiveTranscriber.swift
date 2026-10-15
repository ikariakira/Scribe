import AVFoundation
import Speech

/// Live transcription with SFSpeechRecognizer, which covers the most languages (including
/// Indonesian) on every supported iOS version.
///
/// Server-based recognition only accepts about a minute of audio per request, so the lecture is
/// split into consecutive "passes". A new pass starts at a natural pause (or after 50 s at the
/// latest); the previous one is closed and its final text is delivered when it arrives.
/// All pass bookkeeping happens on the main queue; only `append` runs on the audio thread.
final class LegacyLiveTranscriber: LiveTranscriber {
    private final class Pass {
        let request: SFSpeechAudioBufferRecognitionRequest
        let startTime: TimeInterval
        let createdAt = Date()
        var task: SFSpeechRecognitionTask?
        var latest: SFTranscription?
        var text = ""
        var finished = false

        init(request: SFSpeechAudioBufferRecognitionRequest, startTime: TimeInterval) {
            self.request = request
            self.startTime = startTime
        }
    }

    private static let maxPassLength: TimeInterval = 50
    private static let minPassLength: TimeInterval = 15
    private static let quietTimeBeforeRotating: TimeInterval = 1

    private let recognizer: SFSpeechRecognizer
    private let onDevice: Bool

    // Shared with the audio thread; guarded by `lock`.
    private let lock = NSLock()
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var framesAppended: AVAudioFramePosition = 0
    private var sampleRate: Double = 48_000

    // Main queue only.
    private var current: Pass?
    private var pending: [Pass] = []
    private var isRunning = false
    private var lastTextChange = Date()
    private var failureCount = 0
    private var reportedFailure = false
    private var timer: DispatchSourceTimer?

    init?(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return nil }
        recognizer.queue = .main
        let onDevice = recognizer.supportsOnDeviceRecognition
        self.recognizer = recognizer
        self.onDevice = onDevice
        super.init(engine: onDevice ? .recognizerOnDevice : .recognizerServer)
    }

    override func start(format: AVAudioFormat) async throws {
        lock.withLock { sampleRate = format.sampleRate }
        await MainActor.run {
            self.isRunning = true
            self.beginPass()
            self.startTimer()
        }
    }

    override func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        activeRequest?.append(buffer)
        framesAppended += AVAudioFramePosition(buffer.frameLength)
        lock.unlock()
    }

    override func pause() {
        guard isRunning else { return }
        isRunning = false
        endCurrentPass()
    }

    override func resume() {
        guard !isRunning else { return }
        isRunning = true
        beginPass()
    }

    override func finish() async {
        await MainActor.run {
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.endCurrentPass()
        }
        // Give the recogniser time to return final text for the last passes.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let done = await MainActor.run { self.pending.isEmpty }
            if done { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        await MainActor.run {
            // Anything still outstanding is delivered with its latest partial text.
            for pass in self.pending {
                self.deliver(pass)
                pass.task?.cancel()
            }
            self.pending.removeAll()
        }
        eventSink.finish()
    }

    override func cancel() {
        isRunning = false
        timer?.cancel()
        timer = nil
        lock.withLock { activeRequest = nil }
        var passes = pending
        if let current {
            passes.append(current)
        }
        for pass in passes {
            pass.finished = true
            pass.task?.cancel()
        }
        current = nil
        pending.removeAll()
        eventSink.finish()
    }

    // MARK: Passes (main queue)

    private func beginPass() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        request.taskHint = .dictation

        let startTime: TimeInterval = lock.withLock {
            activeRequest = request
            return Double(framesAppended) / sampleRate
        }
        let pass = Pass(request: request, startTime: startTime)
        current = pass
        lastTextChange = Date()
        pass.task = recognizer.recognitionTask(with: request) { [weak self, weak pass] result, error in
            guard let self, let pass else { return }
            self.handle(pass, result: result, error: error)
        }
    }

    private func endCurrentPass() {
        lock.withLock { activeRequest = nil }
        guard let pass = current else { return }
        current = nil
        pass.request.endAudio()
        pending.append(pass)
        publishVolatile()
    }

    private func rotate() {
        guard let previous = current else { return }
        beginPass()                    // the new request takes over the audio first…
        previous.request.endAudio()    // …then the previous one is closed.
        pending.append(previous)
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.rotateIfNeeded()
        }
        timer.resume()
        self.timer = timer
    }

    private func rotateIfNeeded() {
        guard isRunning, let pass = current else { return }
        let audioTime = lock.withLock { Double(framesAppended) / sampleRate }
        let passLength = audioTime - pass.startTime
        let quietFor = Date().timeIntervalSince(lastTextChange)
        let atNaturalPause = passLength >= Self.minPassLength && quietFor >= Self.quietTimeBeforeRotating && !pass.text.isEmpty
        if passLength >= Self.maxPassLength || atNaturalPause {
            rotate()
        }
    }

    private func handle(_ pass: Pass, result: SFSpeechRecognitionResult?, error: Error?) {
        guard !pass.finished else { return }

        if let result {
            let transcription = result.bestTranscription
            pass.latest = transcription
            let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
            if text != pass.text {
                pass.text = text
                if pass === current {
                    lastTextChange = Date()
                }
            }
            failureCount = 0
            if result.isFinal {
                deliver(pass)
                if pass === current {
                    // The recogniser ended this pass by itself; keep listening with a new one.
                    current = nil
                    lock.withLock { activeRequest = nil }
                    if isRunning {
                        beginPass()
                    }
                }
                return
            }
            publishVolatile()
        }

        guard let error else { return }
        deliver(pass)
        guard pass === current else { return }
        current = nil
        lock.withLock { activeRequest = nil }
        guard isRunning else { return }

        if !SpeechText.isNoSpeech(error) {
            failureCount += 1
            if failureCount >= 3, !reportedFailure {
                reportedFailure = true
                let reason = onDevice
                    ? "the speech recogniser stopped responding"
                    : "Apple's speech service can't be reached. Check your internet connection"
                eventSink.yield(.failed(reason))
            }
        }
        // Back off if passes keep failing straight away (e.g. no internet), otherwise restart now.
        let failedQuickly = Date().timeIntervalSince(pass.createdAt) < 2
        let delay: TimeInterval = failedQuickly ? min(10, 2 * Double(max(1, failureCount))) : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning, self.current == nil else { return }
            self.beginPass()
        }
    }

    private func deliver(_ pass: Pass) {
        guard !pass.finished else { return }
        pass.finished = true
        pending.removeAll { $0 === pass }
        if let transcription = pass.latest {
            for piece in SpeechText.pieces(from: transcription) {
                let segment = TranscriptSegment(
                    start: pass.startTime + piece.start,
                    end: pass.startTime + piece.end,
                    text: piece.text
                )
                eventSink.yield(.finalized(segment))
            }
        }
        publishVolatile()
    }

    private func publishVolatile() {
        var passes = pending
        if let current {
            passes.append(current)
        }
        let text = passes
            .filter { !$0.finished && !$0.text.isEmpty }
            .map(\.text)
            .joined(separator: " ")
        eventSink.yield(.volatile(text))
    }
}
