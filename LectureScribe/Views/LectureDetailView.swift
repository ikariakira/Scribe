import SwiftUI
import UIKit

enum TranscriptStyle: String, CaseIterable, Identifiable {
    case paragraphs
    case timestamps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paragraphs: "Read"
        case .timestamps: "Timestamps"
        }
    }
}

struct LectureDetailView: View {
    let lectureID: UUID

    @Environment(LectureStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.transcriptStyleKey) private var style: TranscriptStyle = .paragraphs
    @State private var player = LecturePlayer()
    @State private var currentSegmentID: UUID?
    @State private var query = ""
    @State private var editingSegment: TranscriptSegment?
    @State private var showDetailsEditor = false
    @State private var showRetranscribe = false
    @State private var confirmDelete = false

    var body: some View {
        if let lecture = store.lecture(id: lectureID) {
            content(for: lecture, job: store.job(for: lectureID))
        } else {
            ContentUnavailableView("Lecture deleted", systemImage: "trash")
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Layout

    private func content(for lecture: Lecture, job: TranscriptionJob) -> some View {
        List {
            Section {
                header(lecture)
            }

            if job.isRunning {
                Section {
                    progress(of: job)
                }
            }

            if let message = job.errorMessage, !job.isRunning {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }

            if lecture.hasTranscript {
                Section {
                    switch style {
                    case .paragraphs:
                        paragraphRows(lecture)
                    case .timestamps:
                        segmentRows(lecture)
                    }
                } header: {
                    transcriptHeader(lecture)
                }
            } else if !job.isRunning {
                Section {
                    emptyTranscript(lecture, job: job)
                }
            }
        }
        .listStyle(.plain)
        .background {
            PlaybackTracker(player: player, segments: lecture.segments, currentID: $currentSegmentID)
        }
        .navigationTitle(lecture.course.isEmpty ? "Lecture" : lecture.course)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Find in transcript")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                actionsMenu(lecture, job: job)
            }
        }
        .safeAreaInset(edge: .bottom) {
            PlayerBar(player: player)
        }
        .onAppear {
            player.load(url: store.audioURL(for: lecture.id), title: lecture.title, subtitle: lecture.course)
        }
        .onDisappear {
            player.teardown()
        }
        .sheet(item: $editingSegment) { segment in
            SegmentEditor(segment: segment) { newText in
                updateSegment(segment.id, text: newText)
            }
        }
        .sheet(isPresented: $showDetailsEditor) {
            LectureDetailsEditor(title: lecture.title, course: lecture.course, courses: store.courses) { title, course in
                store.update(lectureID) { lecture in
                    lecture.title = title
                    lecture.course = course
                }
            }
        }
        .sheet(isPresented: $showRetranscribe) {
            RetranscribeSheet(languageID: lecture.languageID) { languageID in
                job.start(languageID: languageID, store: store)
            }
        }
        .confirmationDialog("Delete this lecture?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Lecture", role: .destructive) {
                player.teardown()
                store.delete(lectureID)
                dismiss()
            }
        } message: {
            Text("The audio and transcript will be permanently removed from this iPhone.")
        }
    }

    private func header(_ lecture: Lecture) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lecture.title)
                .font(.title2.bold())
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 4) {
                Label(lecture.createdAt.formatted(date: .complete, time: .shortened), systemImage: "calendar")
                Label("\(Formatters.duration(lecture.duration)) · \(lecture.wordCount) words", systemImage: "clock")
                Label(languageLine(lecture), systemImage: "globe")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if !lecture.bookmarks.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(lecture.bookmarks.sorted().enumerated()), id: \.offset) { _, time in
                            Button {
                                // Start a few seconds early for context.
                                player.play(from: max(0, time - 5))
                            } label: {
                                Label(Formatters.timestamp(time), systemImage: "star.fill")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
    }

    private func languageLine(_ lecture: Lecture) -> String {
        let language = Formatters.languageName(lecture.languageID)
        guard let engine = lecture.engineName else { return language }
        return "\(language) · \(engine)"
    }

    private func transcriptHeader(_ lecture: Lecture) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Transcript view", selection: $style) {
                ForEach(TranscriptStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            if !trimmedQuery.isEmpty {
                let matches = lecture.segments.filter { $0.text.localizedCaseInsensitiveContains(trimmedQuery) }.count
                Text(matches == 1 ? "1 matching passage" : "\(matches) matching passages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .padding(.vertical, 4)
    }

    // MARK: Transcript

    @ViewBuilder
    private func paragraphRows(_ lecture: Lecture) -> some View {
        let currentID = currentSegmentID
        let highlight = trimmedQuery
        ForEach(Array(lecture.paragraphs.enumerated()), id: \.offset) { _, paragraph in
            ParagraphRow(
                start: paragraph[0].start,
                text: paragraph.map(\.text).joined(separator: " "),
                query: highlight,
                isCurrent: paragraph.contains { $0.id == currentID }
            ) {
                player.play(from: paragraph[0].start)
            }
        }
    }

    @ViewBuilder
    private func segmentRows(_ lecture: Lecture) -> some View {
        let currentID = currentSegmentID
        let highlight = trimmedQuery
        let bookmarked = Set(lecture.bookmarks.compactMap { lecture.segment(at: $0)?.id })
        let visible = highlight.isEmpty
            ? lecture.segments
            : lecture.segments.filter { $0.text.localizedCaseInsensitiveContains(highlight) }
        ForEach(visible) { segment in
            SegmentRow(
                segment: segment,
                query: highlight,
                isCurrent: segment.id == currentID,
                isBookmarked: bookmarked.contains(segment.id)
            ) {
                player.play(from: segment.start)
            }
            .contextMenu {
                Button {
                    player.play(from: segment.start)
                } label: {
                    Label("Play from Here", systemImage: "play.fill")
                }
                Button {
                    UIPasteboard.general.string = segment.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    editingSegment = segment
                } label: {
                    Label("Edit Text", systemImage: "pencil")
                }
            }
        }
    }

    private func emptyTranscript(_ lecture: Lecture, job: TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("No transcript yet", systemImage: "text.badge.xmark")
                .font(.headline)
            Text("Live transcription wasn't available while this was recorded. Transcribe the saved audio now. A long lecture can take a few minutes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                job.start(languageID: lecture.languageID, store: store)
            } label: {
                Label("Transcribe Audio", systemImage: "waveform.and.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.hasAudio(lecture.id))
        }
        .padding(.vertical, 8)
    }

    private func progress(of job: TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.status)
                .font(.subheadline.weight(.medium))
            ProgressView(value: min(max(job.progress, 0), 1))
            HStack {
                Text("\(Int(min(max(job.progress, 0), 1) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) {
                    job.cancel()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Actions

    private func actionsMenu(_ lecture: Lecture, job: TranscriptionJob) -> some View {
        Menu {
            Button {
                showDetailsEditor = true
            } label: {
                Label("Edit Title & Course", systemImage: "pencil")
            }

            Button {
                UIPasteboard.general.string = lecture.exportText(includeTimestamps: style == .timestamps)
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }
            .disabled(!lecture.hasTranscript)

            ShareLink(
                item: TranscriptExport(lecture: lecture, includeTimestamps: style == .timestamps),
                preview: SharePreview("\(lecture.title).txt")
            ) {
                Label("Share Transcript", systemImage: "square.and.arrow.up")
            }

            if store.hasAudio(lecture.id) {
                ShareLink(
                    item: AudioExport(title: lecture.title, sourceURL: store.audioURL(for: lecture.id)),
                    preview: SharePreview("\(lecture.title).m4a")
                ) {
                    Label("Share Audio", systemImage: "waveform")
                }
            }

            Divider()

            Button {
                showRetranscribe = true
            } label: {
                Label("Transcribe Again…", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(job.isRunning || !store.hasAudio(lecture.id))

            Divider()

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete Lecture", systemImage: "trash")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    private func updateSegment(_ segmentID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(lectureID) { lecture in
            guard let index = lecture.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            if trimmed.isEmpty {
                lecture.segments.remove(at: index)
            } else {
                lecture.segments[index].text = trimmed
            }
        }
    }
}

// MARK: - Rows

/// Follows the playback position and reports which segment is being heard. Isolating the
/// 4-per-second time updates here means the transcript only redraws when the segment changes.
private struct PlaybackTracker: View {
    let player: LecturePlayer
    let segments: [TranscriptSegment]
    @Binding var currentID: UUID?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: activeID, initial: true) { _, newValue in
                currentID = newValue
            }
    }

    private var activeID: UUID? {
        guard player.isPlaying || player.currentTime > 0 else { return nil }
        let time = player.currentTime + 0.25
        return segments.last { $0.start <= time }?.id
    }
}

struct ParagraphRow: View {
    let start: TimeInterval
    let text: String
    let query: String
    let isCurrent: Bool
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onPlay) {
                Label(Formatters.timestamp(start), systemImage: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)

            Text(Highlighter.highlight(text, query: query))
                .lineSpacing(5)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.07) : Color.clear)
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let query: String
    let isCurrent: Bool
    let isBookmarked: Bool
    let onPlay: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: onPlay) {
                Text(Formatters.timestamp(segment.start))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.white : Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isCurrent ? Color.accentColor : Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.borderless)

            Text(Highlighter.highlight(segment.text, query: query))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isBookmarked {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.07) : Color.clear)
    }
}

enum Highlighter {
    /// Marks every occurrence of `query` in `text`.
    static func highlight(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard !query.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].backgroundColor = Color.yellow.opacity(0.45)
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
            searchStart = range.upperBound
        }
        return attributed
    }
}
