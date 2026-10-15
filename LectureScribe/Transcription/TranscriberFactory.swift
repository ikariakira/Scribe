import AVFoundation
import Foundation

enum TranscriberFactory {
    /// Returns a started live transcriber, preferring Apple's newest on-device models. It never
    /// waits for a model download, because recording has to start right away, and returns nil when
    /// nothing is available. The audio is still recorded either way.
    static func makeLive(languageID: String, speechAuthorized: Bool, format: AVAudioFormat) async -> LiveTranscriber? {
        let locale = Locale(identifier: languageID)

        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let choice = await SpeechModels.liveChoice(for: locale) {
            let transcriber = AnalyzerLiveTranscriber(choice: choice)
            do {
                try await transcriber.start(format: format)
                return transcriber
            } catch {
                transcriber.cancel()
            }
        }
        #endif

        guard speechAuthorized, let transcriber = LegacyLiveTranscriber(locale: locale) else { return nil }
        do {
            try await transcriber.start(format: format)
            return transcriber
        } catch {
            return nil
        }
    }
}
