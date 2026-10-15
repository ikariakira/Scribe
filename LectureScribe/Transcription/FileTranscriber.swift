import AVFoundation
import Foundation
import Speech

/// Transcribes a saved recording after class. It may download a language model first, but it is
/// usually more accurate than the live transcript and can use a different language.
enum FileTranscriber {
    struct Output: Sendable {
        var segments: [TranscriptSegment]
        var engine: TranscriptionEngine
    }

    typealias ProgressHandler = @Sendable (_ fraction: Double, _ message: String) -> Void

    static func transcribe(
        audioURL: URL,
        languageID: String,
        speechAuthorized: Bool,
        progress: @escaping ProgressHandler
    ) async throws -> Output {
        let locale = Locale(identifier: languageID)
        var analyzerError: Error?

        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let choice = await SpeechModels.bestChoice(for: locale) {
            do {
                let segments = try await transcribeWithAnalyzer(audioURL: audioURL, choice: choice, progress: progress)
                return Output(segments: segments, engine: choice.useDictation ? .dictation : .speechAnalyzer)
            } catch let error as CancellationError {
                throw error
            } catch {
                analyzerError = error
            }
        }
        #endif

        guard speechAuthorized else { throw analyzerError ?? TranscriptionError.notAuthorized }
        do {
            return try await transcribeWithRecognizer(audioURL: audioURL, locale: locale, progress: progress)
        } catch {
            if let analyzerError, (error as? TranscriptionError) == .unsupportedLanguage {
                throw analyzerError
            }
            throw error
        }
    }

    // MARK: iOS 26 SpeechAnalyzer

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private static func transcribeWithAnalyzer(
        audioURL: URL,
        choice: SpeechModels.Choice,
        progress: @escaping ProgressHandler
    ) async throws -> [TranscriptSegment] {
        let file = try AVAudioFile(forReading: audioURL)
        let totalSeconds = max(1, Double(file.length) / file.fileFormat.sampleRate)

        let installed = await SpeechModels.isInstalled(choice)
        if !installed {
            let language = Formatters.languageName(choice.locale.identifier(.bcp47))
            progress(0, "Downloading the \(language) speech model…")
            try await SpeechModels.install(choice)
        }
        let message = "Transcribing on device…"
        progress(0, message)

        let analyzer: SpeechAnalyzer
        let collector: Task<[TranscriptSegment], Error>
        if choice.useDictation {
            let transcriber = SpeechModels.makeDictation(locale: choice.locale, live: false)
            analyzer = SpeechAnalyzer(modules: [transcriber])
            collector = Task {
                var segments: [TranscriptSegment] = []
                for try await result in transcriber.results {
                    guard let segment = SpeechText.segment(from: result.text, range: result.range) else { continue }
                    segments.append(segment)
                    progress(min(1, segment.end / totalSeconds), message)
                }
                return segments
            }
        } else {
            let transcriber = SpeechModels.makeTranscriber(locale: choice.locale, live: false)
            analyzer = SpeechAnalyzer(modules: [transcriber])
            collector = Task {
                var segments: [TranscriptSegment] = []
                for try await result in transcriber.results {
                    guard let segment = SpeechText.segment(from: result.text, range: result.range) else { continue }
                    segments.append(segment)
                    progress(min(1, segment.end / totalSeconds), message)
                }
                return segments
            }
        }

        do {
            if let lastSample = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: lastSample)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
    }
    #endif

    // MARK: SFSpeechRecognizer

    /// Keeps a recognition task alive until it reports back, and makes sure we resume only once.
    private final class RecognitionState: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
        var resumed = false
    }

    /// Feeds the file to the recogniser in 45-second chunks (Apple's servers accept about a minute
    /// of audio per request).
    private static func transcribeWithRecognizer(
        audioURL: URL,
        locale: Locale,
        progress: @escaping ProgressHandler
    ) async throws -> Output {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscriptionError.unsupportedLanguage }
        guard recognizer.isAvailable else { throw TranscriptionError.recognizerUnavailable }
        let onDevice = recognizer.supportsOnDeviceRecognition
        let engine: TranscriptionEngine = onDevice ? .recognizerOnDevice : .recognizerServer
        let message = onDevice ? "Transcribing on device…" : "Transcribing with Apple's speech service…"

        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0 else { return Output(segments: [], engine: engine) }
        let framesPerChunk = AVAudioFramePosition(format.sampleRate * 45)
        let readSize: AVAudioFramePosition = 16_384

        var segments: [TranscriptSegment] = []
        var position: AVAudioFramePosition = 0
        progress(0, message)

        while position < totalFrames {
            try Task.checkCancellation()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = onDevice
            request.addsPunctuation = true
            request.taskHint = .dictation

            let chunkStart = Double(position) / format.sampleRate
            let chunkEnd = min(totalFrames, position + framesPerChunk)
            var reachedEnd = false
            while position < chunkEnd {
                let count = AVAudioFrameCount(min(readSize, chunkEnd - position))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                    throw TranscriptionError.audioUnreadable
                }
                do {
                    try file.read(into: buffer, frameCount: count)
                } catch {
                    if position == 0 { throw error }
                    reachedEnd = true
                    break
                }
                if buffer.frameLength == 0 {
                    reachedEnd = true
                    break
                }
                request.append(buffer)
                position += AVAudioFramePosition(buffer.frameLength)
            }
            request.endAudio()

            for piece in try await recognize(request, with: recognizer) {
                segments.append(TranscriptSegment(start: chunkStart + piece.start, end: chunkStart + piece.end, text: piece.text))
            }
            progress(min(1, Double(position) / Double(totalFrames)), message)
            if reachedEnd { break }
        }
        return Output(segments: segments, engine: engine)
    }

    private static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        with recognizer: SFSpeechRecognizer
    ) async throws -> [RecognizedPiece] {
        try await withCheckedThrowingContinuation { continuation in
            // The handler runs on the recogniser's queue (main), one call at a time.
            let state = RecognitionState()
            state.task = recognizer.recognitionTask(with: request) { result, error in
                guard !state.resumed else { return }
                if let result, result.isFinal {
                    state.resumed = true
                    state.task = nil
                    continuation.resume(returning: SpeechText.pieces(from: result.bestTranscription))
                } else if let error {
                    state.resumed = true
                    state.task = nil
                    if SpeechText.isNoSpeech(error) {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
