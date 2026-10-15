import SwiftUI

struct LectureRow: View {
    let lecture: Lecture
    var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(lecture.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if lecture.isRecording {
                    Label("REC", systemImage: "record.circle")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 6) {
                if !lecture.course.isEmpty {
                    Text(lecture.course)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                Text(lecture.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text(Formatters.duration(lecture.duration))
                if !lecture.bookmarks.isEmpty {
                    Label("\(lecture.bookmarks.count)", systemImage: "star.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(snippet)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private var snippet: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let match = lecture.segments.first(where: { $0.text.localizedCaseInsensitiveContains(trimmed) }) {
            return excerpt(of: match.text, around: trimmed)
        }
        if lecture.hasTranscript {
            return lecture.previewText
        }
        return lecture.isRecording ? "Recording in progress…" : "No transcript yet"
    }

    private func excerpt(of text: String, around query: String) -> String {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return text }
        let start = text.index(range.lowerBound, offsetBy: -50, limitedBy: text.startIndex) ?? text.startIndex
        let prefix = start == text.startIndex ? "" : "…"
        return prefix + String(text[start...])
    }
}
