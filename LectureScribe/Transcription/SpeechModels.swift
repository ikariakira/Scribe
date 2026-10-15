#if compiler(>=6.2)
import Foundation
import Speech

/// Picks and installs iOS 26 SpeechAnalyzer models. SpeechTranscriber (Apple's long-form model)
/// is preferred; DictationTranscriber covers more languages. Both run fully on device once their
/// model has been downloaded.
@available(iOS 26.0, *)
enum SpeechModels {
    struct Choice: Sendable {
        let locale: Locale
        let useDictation: Bool

        var displayName: String {
            useDictation ? "On-device dictation model" : "On-device lecture model"
        }
    }

    static func makeTranscriber(locale: Locale, live: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: live ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange]
        )
    }

    static func makeDictation(locale: Locale, live: Bool) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [.farField],
            transcriptionOptions: [.punctuation],
            reportingOptions: live ? [.volatileResults] : [],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// The best SpeechAnalyzer module for a language, whether or not its model is downloaded yet.
    static func bestChoice(for locale: Locale) async -> Choice? {
        if await SpeechTranscriber.isAvailable,
           let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return Choice(locale: match, useDictation: false)
        }
        return await dictationChoice(for: locale)
    }

    static func dictationChoice(for locale: Locale) async -> Choice? {
        guard let match = await DictationTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        return Choice(locale: match, useDictation: true)
    }

    static func isInstalled(_ choice: Choice) async -> Bool {
        let installed: [Locale]
        if choice.useDictation {
            installed = await DictationTranscriber.installedLocales
        } else {
            installed = await SpeechTranscriber.installedLocales
        }
        let identifier = choice.locale.identifier(.bcp47)
        return installed.contains { $0.identifier(.bcp47) == identifier }
    }

    static func install(_ choice: Choice) async throws {
        let module: any SpeechModule
        if choice.useDictation {
            module = makeDictation(locale: choice.locale, live: false)
        } else {
            module = makeTranscriber(locale: choice.locale, live: false)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    /// For live recording, which must start immediately: returns a module whose model is already
    /// on the device. If the best model is missing, it starts downloading it for next time.
    static func liveChoice(for locale: Locale) async -> Choice? {
        guard let best = await bestChoice(for: locale) else { return nil }
        if await isInstalled(best) {
            return best
        }
        Task.detached {
            try? await SpeechModels.install(best)
        }
        if !best.useDictation,
           let dictation = await dictationChoice(for: locale),
           await isInstalled(dictation) {
            return dictation
        }
        return nil
    }
}
#endif
