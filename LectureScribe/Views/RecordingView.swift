import SwiftUI

struct RecordingView: View {
    @Bindable var session: RecordingSession
    /// Called with the saved lecture's id, or nil if the recording was discarded.
    let onClose: (UUID?) -> Void

    @State private var confirmDiscard = false

    // The details, transcript and controls are separate views so the 10-per-second meter and
    // clock updates don't redraw a long transcript.
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RecordingDetails(session: session)
                Divider()
                LiveTranscript(session: session) {
                    session.discard()
                    onClose(nil)
                }
                RecordingControls(session: session) {
                    Task {
                        await session.stop()
                        onClose(session.lecture.id)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .destructive) {
                        if session.isLive {
                            confirmDiscard = true
                        } else {
                            session.discard()
                            onClose(nil)
                        }
                    }
                    .disabled(session.phase == .finishing)
                }
                ToolbarItem(placement: .principal) {
                    RecordingStatusBadge(phase: session.phase)
                }
            }
            .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Recording", role: .destructive) {
                    session.discard()
                    onClose(nil)
                }
                Button("Keep Recording", role: .cancel) {}
            } message: {
                Text("The audio and transcript captured so far will be deleted.")
            }
        }
        .overlay {
            if session.phase == .finishing {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView("Saving transcript…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .interactiveDismissDisabled()
        .task {
            await session.start()
        }
    }
}

// MARK: - Details

private struct RecordingDetails: View {
    @Bindable var session: RecordingSession
    @Environment(LectureStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Lecture title", text: $session.lecture.title)
                .font(.title3.weight(.semibold))
                .submitLabel(.done)

            HStack(spacing: 8) {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
                TextField("Course (optional)", text: $session.lecture.course)
                    .submitLabel(.done)
                if !store.courses.isEmpty {
                    Menu {
                        ForEach(store.courses, id: \.self) { course in
                            Button(course) {
                                session.lecture.course = course
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .accessibilityLabel("Choose a course")
                }
            }
            .font(.subheadline)

            HStack(spacing: 6) {
                Image(systemName: "globe")
                Text(Formatters.languageName(session.lecture.languageID))
                if let engine = session.engine {
                    Text("·")
                    Text(engine.displayName)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
    }
}

// MARK: - Live transcript

private struct LiveTranscript: View {
    let session: RecordingSession
    let onCloseAfterFailure: () -> Void

    private static let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let notice = session.notice {
                        NoticeView(text: notice)
                    }

                    if case .failed(let message) = session.phase {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Recording couldn't start", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.orange)
                            Text(message)
                            Button("Close", action: onCloseAfterFailure)
                                .buttonStyle(.borderedProminent)
                        }
                    }

                    ForEach(session.lecture.segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(Formatters.timestamp(segment.start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(segment.text)
                        }
                    }

                    if !session.volatileText.isEmpty {
                        Text(session.volatileText)
                            .foregroundStyle(.secondary)
                    } else if session.phase == .starting {
                        ProgressView("Getting ready…")
                    } else if session.lecture.segments.isEmpty, session.phase == .recording, session.engine != nil {
                        Label("Listening…", systemImage: "ear")
                            .foregroundStyle(.secondary)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: session.lecture.segments.count) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: session.volatileText) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }
}

// MARK: - Controls

private struct RecordingControls: View {
    let session: RecordingSession
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            LevelMeter(levels: session.levels, isActive: session.phase == .recording)
                .frame(height: 34)

            Text(Formatters.timestamp(session.elapsed))
                .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())

            HStack(spacing: 36) {
                RoundControl(title: bookmarkTitle, systemImage: "star.fill", tint: .orange) {
                    session.addBookmark()
                }
                .disabled(!session.isLive)

                pauseResumeButton

                RoundControl(title: "Stop & Save", systemImage: "stop.fill", tint: .red, action: onStop)
                    .disabled(!session.isLive)
            }
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .sensoryFeedback(.impact, trigger: session.lecture.bookmarks.count)
    }

    private var bookmarkTitle: String {
        let count = session.lecture.bookmarks.count
        return count == 0 ? "Bookmark" : "Bookmark (\(count))"
    }

    private var pauseResumeButton: some View {
        let isPaused = session.phase == .paused
        return Button {
            if isPaused {
                session.resume()
            } else {
                session.pause()
            }
        } label: {
            Image(systemName: isPaused ? "mic.fill" : "pause.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 80, height: 80)
                .background(isPaused ? Color.red : Color.orange, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!session.isLive)
        .opacity(session.isLive ? 1 : 0.4)
        .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")
    }
}

private struct RecordingStatusBadge: View {
    let phase: RecordingSession.Phase

    var body: some View {
        switch phase {
        case .recording:
            Label("Recording", systemImage: "record.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating)
        case .paused:
            Label("Paused", systemImage: "pause.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
        case .starting:
            Text("Starting…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        case .finishing:
            Text("Saving…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        case .idle, .finished, .failed:
            EmptyView()
        }
    }
}

// MARK: - Shared pieces

struct NoticeView: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)
        }
        .font(.footnote)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct RoundControl: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 58, height: 58)
                    .background(tint.opacity(0.15), in: Circle())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }
}

struct LevelMeter: View {
    let levels: [Float]
    var isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 3
            let count = CGFloat(max(levels.count, 1))
            let barWidth = max(1, (geometry.size.width - spacing * (count - 1)) / count)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? Color.red.opacity(0.85) : Color.secondary.opacity(0.35))
                        .frame(width: barWidth, height: max(3, CGFloat(levels[index]) * geometry.size.height))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .animation(.linear(duration: 0.1), value: levels)
        .accessibilityHidden(true)
    }
}
