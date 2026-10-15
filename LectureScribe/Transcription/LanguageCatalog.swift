import Foundation
import Speech

struct LanguageOption: Identifiable, Hashable, Sendable {
    /// BCP-47 identifier, e.g. "en-US".
    let id: String
    let name: String
    /// Supported by Apple's newest on-device lecture model (iOS 26 and later).
    let usesAdvancedModel: Bool
}

enum LanguageCatalog {
    /// The phone's own language if speech recognition supports it, otherwise US English.
    static let defaultLanguageID: String = {
        let supported = SFSpeechRecognizer.supportedLocales().map { $0.identifier(.bcp47) }.sorted()
        let current = Locale.current.identifier(.bcp47)
        if supported.contains(current) {
            return current
        }
        if let code = Locale.current.language.languageCode?.identifier,
           let match = supported.first(where: { $0.hasPrefix(code + "-") }) {
            return match
        }
        return "en-US"
    }()

    static func load() async -> [LanguageOption] {
        var identifiers = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier(.bcp47) })
        var advanced = Set<String>()
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            for locale in await SpeechTranscriber.supportedLocales {
                let identifier = locale.identifier(.bcp47)
                identifiers.insert(identifier)
                advanced.insert(identifier)
            }
        }
        #endif
        return identifiers
            .map { LanguageOption(id: $0, name: Formatters.languageName($0), usesAdvancedModel: advanced.contains($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
