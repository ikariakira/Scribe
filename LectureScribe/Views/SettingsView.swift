import Observation
import SwiftUI

struct SettingsView: View {
    @Environment(LectureStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.languageKey) private var languageID = LanguageCatalog.defaultLanguageID
    @AppStorage(AppSettings.keepScreenOnKey) private var keepScreenOn = false
    @State private var model = SpeechModelStatus()
    @State private var storageUsed: Int64 = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        LanguagePickerView(selection: $languageID)
                    } label: {
                        LabeledContent("Lecture language", value: Formatters.languageName(languageID))
                    }
                    modelRow
                } header: {
                    Text("Transcription")
                } footer: {
                    Text("Pick the language your lecturer speaks. Download the on-device model before class and live transcription will work even without Wi-Fi.")
                }

                Section {
                    Toggle("Keep screen on while recording", isOn: $keepScreenOn)
                } footer: {
                    Text("Recording carries on when you lock your iPhone. Keeping the screen on lets you watch the live transcript, but uses more battery.")
                }

                Section("Storage") {
                    LabeledContent("Lectures", value: "\(store.lectures.count)")
                    LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: storageUsed, countStyle: .file))
                }

                Section("Tips for better transcripts") {
                    tip("iphone.gen3", "Sit near the front, or put your phone face-up as close to the lecturer as you can.")
                    tip("lock.fill", "Recording keeps going with the screen locked, so you can put your phone away.")
                    tip("star.fill", "Tap Bookmark whenever the lecturer says something important, like what's on the exam.")
                    tip("arrow.triangle.2.circlepath", "After class, use Transcribe Again for a cleaner transcript or a different language.")
                    tip("folder.fill", "Your recordings and transcripts also appear in the Files app under On My iPhone › LectureScribe.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: languageID) {
                await model.refresh(languageID: languageID)
            }
            .task {
                storageUsed = store.storageUsed()
            }
        }
    }

    @ViewBuilder
    private var modelRow: some View {
        switch model.state {
        case .checking:
            LabeledContent("On-device model") {
                ProgressView()
            }
        case .standardOnly:
            LabeledContent("Engine", value: "Standard speech recognition")
        case .ready(let name):
            LabeledContent(name) {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .needsDownload(let name):
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text("Not downloaded yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") {
                    Task { await model.download(languageID: languageID) }
                }
                .buttonStyle(.bordered)
            }
        case .downloading(let name):
            LabeledContent(name) {
                HStack(spacing: 6) {
                    ProgressView()
                    Text("Downloading…")
                }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    private func tip(_ systemImage: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(.footnote)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
        }
    }
}

/// Whether the on-device speech model for a language is on the phone, and downloads it on request.
@MainActor
@Observable
final class SpeechModelStatus {
    enum State: Equatable {
        case checking
        case standardOnly
        case ready(String)
        case needsDownload(String)
        case downloading(String)
        case failed(String)
    }

    private(set) var state: State = .checking

    func refresh(languageID: String) async {
        state = .checking
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            guard let choice = await SpeechModels.bestChoice(for: Locale(identifier: languageID)) else {
                state = .standardOnly
                return
            }
            let installed = await SpeechModels.isInstalled(choice)
            state = installed ? .ready(choice.displayName) : .needsDownload(choice.displayName)
            return
        }
        #endif
        state = .standardOnly
    }

    func download(languageID: String) async {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            guard let choice = await SpeechModels.bestChoice(for: Locale(identifier: languageID)) else { return }
            state = .downloading(choice.displayName)
            do {
                try await SpeechModels.install(choice)
                state = .ready(choice.displayName)
            } catch {
                state = .failed("Download failed: \(error.localizedDescription)")
            }
        }
        #endif
    }
}
