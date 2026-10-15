import AVFoundation
import Observation
import UIKit

/// Runs one lecture recording: microphone capture to disk, live transcription, pause/resume,
/// interruptions (phone calls) and periodic saving so little is lost if the app is closed.
@MainActor
@Observable
final class RecordingSession: Identifiable {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case paused
        case finishing
        case finished
        case failed(String)
    }

    let id = UUID()
    private(set) var phase: Phase = .idle
    var lecture: Lecture
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [Float] = Array(repeating: 0, count: 48)
    private(set) var volatileText = ""
    private(set) var engine: TranscriptionEngine? = nil
    var notice: String? = nil

    var isLive: Bool {
        phase == .recording || phase == .paused
    }

    private let store: LectureStore
    private let keepScreenOn: Bool
    private let capture = AudioCapture()
    @ObservationIgnored private var transcriber: LiveTranscriber?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionTask: Task<Void, Never>?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var pausedByInterruption = false

    init(store: LectureStore, languageID: String, course: String, keepScreenOn: Bool) {
        self.store = store
        self.keepScreenOn = keepScreenOn
        let stamp = Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        let title = course.isEmpty ? "Lecture · \(stamp)" : "\(course) · \(stamp)"
        lecture = Lecture(title: title, course: course, languageID: languageID)
    }

    // MARK: Controls

    func start() async {
        guard phase == .idle else { return }
        phase = .starting

        guard await Permissions.requestMicrophone() else {
            phase = .failed("LectureScribe needs the microphone to record. Turn it on in Settings › Privacy & Security › Microphone.")
            return
        }
        let speechAuthorized = await Permissions.requestSpeech()

        do {
            try AudioSessionController.activateForRecording()
            let format = try capture.prepare()

            let transcriber = await TranscriberFactory.makeLive(
                languageID: lecture.languageID,
                speechAuthorized: speechAuthorized,
                format: format
            )
            self.transcriber = transcriber
            if let transcriber {
                engine = transcriber.engine
                lecture.engine = transcriber.engine.rawValue
                listen(to: transcriber)
            } else if speechAuthorized {
                notice = "Live transcription isn't available for \(Formatters.languageName(lecture.languageID)) right now (it may need internet). The audio is still being recorded — open the lecture afterwards and tap Transcribe Audio."
            } else {
                notice = "Speech recognition is turned off for LectureScribe, so only audio is being recorded. You can turn it on in Settings › Privacy & Security › Speech Recognition."
            }

            try FileManager.default.createDirectory(at: store.folderURL(for: lecture.id), withIntermediateDirectories: true)
            try capture.start(fileURL: store.audioURL(for: lecture.id)) { [transcriber] buffer in
                transcriber?.append(buffer)
            }

            lecture.isRecording = true
            store.save(lecture)
            lastSave = Date()
            phase = .recording
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
            startTicking()
            observeInterruptions()
            observeTermination()
        } catch {
            transcriber?.cancel()
            transcriber = nil
            eventsTask?.cancel()
            capture.stop()
            AudioSessionController.deactivate()
            phase = .failed("Recording couldn't start: \(error.localizedDescription)")
        }
    }

    func pause() {
        guard phase == .recording else { return }
        capture.pause()
        transcriber?.pause()
        elapsed = capture.duration
        lecture.duration = elapsed
        store.save(lecture)
        lastSave = Date()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        do {
            try AudioSessionController.activateForRecording()
            try capture.resume()
            transcriber?.resume()
            pausedByInterruption = false
            phase = .recording
        } catch {
            notice = "Couldn't resume recording: \(error.localizedDescription)"
        }
    }

    func addBookmark() {
        guard isLive else { return }
        lecture.bookmarks.append(capture.duration)
        store.save(lecture)
        lastSave = Date()
    }

    /// Stops recording, waits briefly for the last words to be transcribed, and saves.
    func stop() async {
        guard isLive else { return }
        phase = .finishing
        stopObserving()
        capture.stop()
        elapsed = capture.duration

        if let transcriber {
            await transcriber.finish()
            await eventsTask?.value
        }
        let leftover = volatileText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !leftover.isEmpty {
            // Keep words the recogniser never got round to finalising.
            let start = lecture.segments.last?.end ?? 0
            insert(TranscriptSegment(start: start, end: max(start, elapsed), text: leftover))
        }
        volatileText = ""

        lecture.duration = elapsed
        lecture.isRecording = false
        store.save(lecture)
        AudioSessionController.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .finished
    }

    /// Throws the recording away.
    func discard() {
        stopObserving()
        capture.stop()
        transcriber?.cancel()
        eventsTask?.cancel()
        store.delete(lecture.id)
        AudioSessionController.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .finished
    }

    // MARK: Transcript

    private func listen(to transcriber: LiveTranscriber) {
        eventsTask = Task { [weak self] in
            for await event in transcriber.events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: TranscriptEvent) {
        switch event {
        case .volatile(let text):
            volatileText = text
        case .finalized(let segment):
            insert(segment)
            saveIfDue()
        case .failed(let message):
            notice = "Live transcription is having trouble (\(message)). The audio is still being recorded, so you can transcribe it afterwards."
        }
    }

    private func insert(_ segment: TranscriptSegment) {
        let index = lecture.segments.firstIndex { $0.start > segment.start } ?? lecture.segments.endIndex
        lecture.segments.insert(segment, at: index)
    }

    // MARK: Housekeeping

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        elapsed = capture.duration
        if phase == .recording {
            levels.removeFirst()
            levels.append(capture.level)
        }
        if capture.hasWriteError, notice == nil {
            notice = "Audio couldn't be saved. Is your iPhone's storage full?"
        }
        saveIfDue()
    }

    private func saveIfDue() {
        guard isLive, Date().timeIntervalSince(lastSave) > 15 else { return }
        lastSave = Date()
        lecture.duration = capture.duration
        store.save(lecture)
    }

    private func observeInterruptions() {
        interruptionTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                guard let self else { return }
                self.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            guard phase == .recording else { return }
            pause()
            pausedByInterruption = true
            notice = "Paused because another app needed the audio (for example, a phone call)."
        case .ended:
            guard pausedByInterruption, phase == .paused else { return }
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                resume()
                if phase == .recording {
                    notice = nil
                }
            }
        @unknown default:
            break
        }
    }

    /// If the app is swiped away mid-lecture, close the audio file properly so it stays playable.
    private func observeTermination() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveBeforeTermination()
            }
        }
    }

    private func saveBeforeTermination() {
        guard isLive else { return }
        capture.stop()
        lecture.duration = capture.duration
        lecture.isRecording = false
        store.save(lecture)
    }

    private func stopObserving() {
        tickTask?.cancel()
        tickTask = nil
        interruptionTask?.cancel()
        interruptionTask = nil
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        terminationObserver = nil
    }
}
