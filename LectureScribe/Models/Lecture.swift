import Foundation

/// One finalised stretch of transcript, timed against the lecture's audio.
struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Seconds from the start of the recording.
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// A recorded lecture. Stored as `lecture.json` next to its `audio.m4a`.
struct Lecture: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var course = ""
    var createdAt = Date()
    var duration: TimeInterval = 0
    /// BCP-47 language the transcript was made in, e.g. "en-US" or "id-ID".
    var languageID: String
    /// Raw value of the `TranscriptionEngine` that produced the transcript.
    var engine = ""
    var segments: [TranscriptSegment] = []
    /// Moments (seconds from the start) the student marked as important.
    var bookmarks: [TimeInterval] = []
    /// True while audio is still being captured; recovered on next launch if the app quits mid-lecture.
    var isRecording = false
}

extension Lecture: Codable {
    enum CodingKeys: String, CodingKey {
        case id, title, course, createdAt, duration, languageID, engine, segments, bookmarks, isRecording
    }

    // Decodes leniently so older or partially written files still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Untitled lecture"
        course = try container.decodeIfPresent(String.self, forKey: .course) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        languageID = try container.decodeIfPresent(String.self, forKey: .languageID) ?? "en-US"
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? ""
        segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
        bookmarks = try container.decodeIfPresent([TimeInterval].self, forKey: .bookmarks) ?? []
        isRecording = try container.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
    }
}

extension Lecture {
    var hasTranscript: Bool {
        segments.contains { !$0.text.isEmpty }
    }

    var plainText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    var previewText: String {
        String(plainText.prefix(180))
    }

    var engineName: String? {
        TranscriptionEngine(rawValue: engine)?.displayName
    }

    /// The segment being spoken at `time`.
    func segment(at time: TimeInterval) -> TranscriptSegment? {
        segments.last { $0.start <= time }
    }

    /// Groups segments into readable paragraphs, breaking at long pauses or after a few sentences.
    var paragraphs: [[TranscriptSegment]] {
        var result: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var length = 0
        for segment in segments where !segment.text.isEmpty {
            if let previous = current.last {
                let pause = segment.start - previous.end
                let endsSentence = previous.text.last.map { ".?!".contains($0) } ?? false
                if pause > 4 || (length > 650 && endsSentence) || length > 1400 {
                    result.append(current)
                    current = []
                    length = 0
                }
            }
            current.append(segment)
            length += segment.text.count
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    /// Plain-text export used for copying and sharing.
    func exportText(includeTimestamps: Bool) -> String {
        var lines: [String] = [title]
        var details: [String] = []
        if !course.isEmpty {
            details.append(course)
        }
        details.append(createdAt.formatted(date: .long, time: .shortened))
        details.append(Formatters.duration(duration))
        lines.append(details.joined(separator: " · "))
        lines.append("")

        if includeTimestamps {
            for segment in segments {
                lines.append("[\(Formatters.timestamp(segment.start))] \(segment.text)")
            }
        } else {
            for paragraph in paragraphs {
                lines.append(paragraph.map(\.text).joined(separator: " "))
                lines.append("")
            }
        }

        if !bookmarks.isEmpty {
            lines.append("")
            lines.append("Bookmarks")
            for time in bookmarks.sorted() {
                let context = segment(at: time)?.text ?? ""
                lines.append("★ \(Formatters.timestamp(time))  \(context)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
