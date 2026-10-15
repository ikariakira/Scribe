import CoreMedia
import Foundation
import Speech

/// Recognised speech with times relative to the start of the audio it came from.
struct RecognizedPiece: Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

enum SpeechText {
    /// Splits an SFSpeechRecognizer transcription into sentence-sized pieces using its per-word
    /// timings, so long passes become several tappable, timestamped lines.
    static func pieces(from transcription: SFTranscription) -> [RecognizedPiece] {
        let full = transcription.formattedString as NSString
        let wholeText = (full as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wholeText.isEmpty else { return [] }
        let words = transcription.segments
        guard let firstWord = words.first, let lastWord = words.last else {
            return [RecognizedPiece(text: wholeText, start: 0, end: 0)]
        }
        let whole = RecognizedPiece(text: wholeText, start: firstWord.timestamp, end: lastWord.timestamp + lastWord.duration)

        var pieces: [RecognizedPiece] = []
        var pieceFirstWord = 0
        var pieceLocation = 0
        for (index, word) in words.enumerated() {
            let range = word.substringRange
            let wordEnd = range.location + range.length
            let nextLocation = index + 1 < words.count ? words[index + 1].substringRange.location : full.length
            // Word ranges should move forward through the text; if not, keep it as one piece.
            guard range.location >= pieceLocation, wordEnd <= full.length,
                  nextLocation >= wordEnd, nextLocation <= full.length else {
                return [whole]
            }
            let wordAndGap = full.substring(with: NSRange(location: range.location, length: nextLocation - range.location))
            let endsSentence = wordAndGap.contains { ".?!".contains($0) }
            let wordsInPiece = index - pieceFirstWord + 1
            let isLastWord = index == words.count - 1
            if isLastWord || (endsSentence && wordsInPiece >= 4) || wordsInPiece >= 40 {
                let text = full.substring(with: NSRange(location: pieceLocation, length: nextLocation - pieceLocation))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    pieces.append(RecognizedPiece(
                        text: text,
                        start: words[pieceFirstWord].timestamp,
                        end: word.timestamp + word.duration
                    ))
                }
                pieceFirstWord = index + 1
                pieceLocation = nextLocation
            }
        }
        return pieces.isEmpty ? [whole] : pieces
    }

    /// Recogniser errors that only mean nobody spoke during that stretch of audio.
    static func isNoSpeech(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "kAFAssistantErrorDomain" && [203, 1110].contains(nsError.code)
    }

    /// Builds a segment from a SpeechAnalyzer result.
    static func segment(from text: AttributedString, range: CMTimeRange) -> TranscriptSegment? {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        let rawStart = range.start.seconds
        let start = rawStart.isFinite ? max(0, rawStart) : 0
        let rawEnd = range.end.seconds
        let end = rawEnd.isFinite ? max(start, rawEnd) : start
        return TranscriptSegment(start: start, end: end, text: plain)
    }
}
