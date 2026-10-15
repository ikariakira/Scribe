import Foundation
import Observation

/// Transcribes (or re-transcribes) a lecture's saved audio in the background and replaces its
/// transcript when done.
@MainActor
@Observable
final class TranscriptionJob {
    let lectureID: UUID
    private(set) var isRunning = false
    private(set) var progress: Double = 0
    private(set) var status = ""
    private(set) var errorMessage: String? = nil

    @ObservationIgnored private var task: Task<Void, Never>?

    init(lectureID: UUID) {
        self.lectureID = lectureID
    }

    func start(languageID: String, store: LectureStore) {
        guard !isRunning else { return }
        isRunning = true
        progress = 0
        status = "Preparing…"
        errorMessage = nil

        let lectureID = lectureID
        let audioURL = store.audioURL(for: lectureID)
        let job = self
        task = Task {
            let speechAuthorized = await Permissions.requestSpeech()
            do {
                let output = try await FileTranscriber.transcribe(
                    audioURL: audioURL,
                    languageID: languageID,
                    speechAuthorized: speechAuthorized
                ) { fraction, message in
                    Task { @MainActor in
                        guard job.isRunning else { return }
                        job.progress = fraction
                        job.status = message
                    }
                }
                try Task.checkCancellation()
                store.update(lectureID) { lecture in
                    lecture.segments = output.segments
                    lecture.languageID = languageID
                    lecture.engine = output.engine.rawValue
                }
                if output.segments.isEmpty {
                    job.errorMessage = "No speech was recognised in this recording. Check that the language is right."
                }
            } catch is CancellationError {
                // Cancelled: the existing transcript is left untouched.
            } catch {
                job.errorMessage = error.localizedDescription
            }
            job.isRunning = false
            job.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        status = ""
    }
}
