import SwiftUI

struct LibraryView: View {
    @Environment(LectureStore.self) private var store
    @AppStorage(AppSettings.languageKey) private var languageID = LanguageCatalog.defaultLanguageID
    @AppStorage(AppSettings.keepScreenOnKey) private var keepScreenOn = false

    @State private var path: [UUID] = []
    @State private var searchText = ""
    @State private var courseFilter: String?
    @State private var session: RecordingSession?
    @State private var showSettings = false
    @State private var showLanguagePicker = false
    @State private var lectureToDelete: Lecture?

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Lectures")
                .searchable(text: $searchText, prompt: "Search titles and transcripts")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                .navigationDestination(for: UUID.self) { id in
                    LectureDetailView(lectureID: id)
                }
                .safeAreaInset(edge: .bottom) {
                    recordBar
                }
        }
        .fullScreenCover(item: $session) { session in
            RecordingView(session: session) { savedID in
                self.session = nil
                if let savedID {
                    path = [savedID]
                }
            }
            .environment(store)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(store)
        }
        .sheet(isPresented: $showLanguagePicker) {
            NavigationStack {
                LanguagePickerView(selection: $languageID)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { showLanguagePicker = false }
                        }
                    }
            }
        }
        .confirmationDialog(
            "Delete this lecture?",
            isPresented: Binding(
                get: { lectureToDelete != nil },
                set: { if !$0 { lectureToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: lectureToDelete
        ) { lecture in
            Button("Delete Lecture", role: .destructive) {
                store.delete(lecture.id)
            }
        } message: { lecture in
            Text("“\(lecture.title)” and its audio will be permanently removed from this iPhone.")
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.lectures.isEmpty {
            ContentUnavailableView {
                Label("No lectures yet", systemImage: "waveform.badge.mic")
            } description: {
                Text("Tap **Record Lecture** when class starts. You'll get the audio plus a transcript you can read, search and share later.")
            }
        } else {
            List {
                if !store.courses.isEmpty {
                    courseChips
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(filteredLectures) { lecture in
                    NavigationLink(value: lecture.id) {
                        LectureRow(lecture: lecture, query: searchText)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            lectureToDelete = lecture
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if filteredLectures.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView("No lectures in this course", systemImage: "tray")
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
        }
    }

    private var filteredLectures: [Lecture] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.lectures.filter { lecture in
            if let courseFilter, lecture.course != courseFilter {
                return false
            }
            guard !query.isEmpty else { return true }
            return lecture.title.localizedCaseInsensitiveContains(query)
                || lecture.course.localizedCaseInsensitiveContains(query)
                || lecture.segments.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    private var courseChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isSelected: courseFilter == nil) {
                    courseFilter = nil
                }
                ForEach(store.courses, id: \.self) { course in
                    chip(course, isSelected: courseFilter == course) {
                        courseFilter = courseFilter == course ? nil : course
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Recording

    private var recordBar: some View {
        VStack(spacing: 10) {
            Button {
                showLanguagePicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text("Lecture language: \(Formatters.languageName(languageID))")
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Button(action: startRecording) {
                Label("Record Lecture", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.red)
            .disabled(session != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func startRecording() {
        session = RecordingSession(
            store: store,
            languageID: languageID,
            course: courseFilter ?? "",
            keepScreenOn: keepScreenOn
        )
    }
}
