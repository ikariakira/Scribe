import AVFoundation
import Foundation

enum TranscriptionEngine: String, Codable, Sendable {
    /// iOS 26 SpeechAnalyzer + SpeechTranscriber: Apple's long-form, on-device model.
    case speechAnalyzer
    /// iOS 26 SpeechAnalyzer + DictationTranscriber: on-device dictation model, more languages.
    case dictation
    /// SFSpeechRecognizer running on the device.
    case recognizerOnDevice
    /// SFSpeechRecognizer using Apple's servers (needs internet).
    case recognizerServer

    var displayName: String {
        switch self {
        case .speechAnalyzer: "Apple on-device model"
        case .dictation: "Apple on-device dictation"
        case .recognizerOnDevice: "On-device speech recognition"
        case .recognizerServer: "Apple speech service (online)"
        }
    }
}

enum TranscriptEvent: Sendable {
    /// Tentative text for speech that hasn't been finalised yet. Replaces the previous one.
    case volatile(String)
    case finalized(TranscriptSegment)
    /// Something went wrong; the recording itself carries on.
    case failed(String)
}

enum TranscriptionError: LocalizedError {
    case unsupportedLanguage
    case recognizerUnavailable
    case unsupportedAudioFormat
    case audioUnreadable
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage:
            "Speech recognition doesn't support this language on your iPhone."
        case .recognizerUnavailable:
            "Speech recognition isn't available right now. Check your internet connection and try again."
        case .unsupportedAudioFormat:
            "The speech model can't read this audio format."
        case .audioUnreadable:
            "The recording couldn't be read."
        case .notAuthorized:
            "Speech recognition is turned off for LectureScribe. Turn it on in Settings › Privacy & Security › Speech Recognition."
        }
    }
}

/// Base class for live transcribers. Audio arrives on the capture thread through `append(_:)`;
/// results come out of `events`, in order.
class LiveTranscriber: @unchecked Sendable {
    let engine: TranscriptionEngine
    let events: AsyncStream<TranscriptEvent>
    let eventSink: AsyncStream<TranscriptEvent>.Continuation

    init(engine: TranscriptionEngine) {
        self.engine = engine
        let pair = AsyncStream.makeStream(of: TranscriptEvent.self)
        events = pair.stream
        eventSink = pair.continuation
    }

    /// Prepares to receive audio in `format`. Throws if transcription can't start.
    func start(format: AVAudioFormat) async throws {}

    /// Called on the audio thread for every captured buffer.
    func append(_ buffer: AVAudioPCMBuffer) {}

    /// Called on the main thread when recording pauses.
    func pause() {}

    /// Called on the main thread when recording resumes.
    func resume() {}

    /// Delivers any remaining results, then ends `events`.
    func finish() async {
        eventSink.finish()
    }

    /// Stops straight away, dropping anything pending. Called on the main thread.
    func cancel() {
        eventSink.finish()
    }
}

/// A thread-safe flag for waiting on work with a timeout.
final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    var isSet: Bool {
        lock.withLock { done }
    }

    func set() {
        lock.withLock { done = true }
    }

    /// Returns once the flag is set or `timeout` seconds have passed.
    func wait(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isSet, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
