#if compiler(>=6.2)
import AVFoundation
import CoreMedia
import Speech

/// Live transcription with iOS 26's SpeechAnalyzer: fully on device, designed for long-form
/// audio such as lectures, and no one-minute limit.
@available(iOS 26.0, *)
final class AnalyzerLiveTranscriber: LiveTranscriber {
    private let choice: SpeechModels.Choice

    // Shared with the audio thread; guarded by `lock`.
    private let lock = NSLock()
    private let converter = BufferConverter()
    private var analyzerFormat: AVAudioFormat?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?

    private var resultsTask: Task<Void, Never>?

    init(choice: SpeechModels.Choice) {
        self.choice = choice
        super.init(engine: choice.useDictation ? .dictation : .speechAnalyzer)
    }

    override func start(format: AVAudioFormat) async throws {
        let sink = eventSink
        let module: any SpeechModule
        if choice.useDictation {
            let transcriber = SpeechModels.makeDictation(locale: choice.locale, live: true)
            module = transcriber
            resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        AnalyzerLiveTranscriber.publish(result.text, range: result.range, isFinal: result.isFinal, to: sink)
                    }
                } catch {
                    sink.yield(.failed(error.localizedDescription))
                }
            }
        } else {
            let transcriber = SpeechModels.makeTranscriber(locale: choice.locale, live: true)
            module = transcriber
            resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        AnalyzerLiveTranscriber.publish(result.text, range: result.range, isFinal: result.isFinal, to: sink)
                    }
                } catch {
                    sink.yield(.failed(error.localizedDescription))
                }
            }
        }

        do {
            guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: format) else {
                throw TranscriptionError.unsupportedAudioFormat
            }
            let (stream, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [module])
            try await analyzer.prepareToAnalyze(in: analyzerFormat)
            try await analyzer.start(inputSequence: stream)
            lock.withLock {
                self.analyzerFormat = analyzerFormat
                self.inputBuilder = builder
                self.analyzer = analyzer
            }
        } catch {
            resultsTask?.cancel()
            throw error
        }
    }

    override func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let analyzerFormat, let inputBuilder,
              let converted = try? converter.convert(buffer, to: analyzerFormat) else { return }
        inputBuilder.yield(AnalyzerInput(buffer: converted))
    }

    override func pause() {
        // Turn the tentative text into final text so nothing hangs in limbo during the pause.
        guard let analyzer = lock.withLock({ self.analyzer }) else { return }
        Task {
            try? await analyzer.finalize(through: nil)
        }
    }

    override func finish() async {
        let builder: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            let current = inputBuilder
            inputBuilder = nil
            return current
        }
        let analyzer = lock.withLock { self.analyzer }
        builder?.finish()

        let done = CompletionFlag()
        let resultsTask = self.resultsTask
        Task {
            if let analyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            await resultsTask?.value
            done.set()
        }
        await done.wait(timeout: 15)
        resultsTask?.cancel()
        eventSink.finish()
    }

    override func cancel() {
        let analyzer: SpeechAnalyzer? = lock.withLock {
            inputBuilder?.finish()
            inputBuilder = nil
            let existing = self.analyzer
            self.analyzer = nil
            return existing
        }
        resultsTask?.cancel()
        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        eventSink.finish()
    }

    private static func publish(
        _ text: AttributedString,
        range: CMTimeRange,
        isFinal: Bool,
        to sink: AsyncStream<TranscriptEvent>.Continuation
    ) {
        if isFinal {
            if let segment = SpeechText.segment(from: text, range: range) {
                sink.yield(.finalized(segment))
            }
            sink.yield(.volatile(""))
        } else {
            let tentative = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            sink.yield(.volatile(tentative))
        }
    }
}
#endif
