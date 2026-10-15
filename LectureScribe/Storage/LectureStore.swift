import Foundation
import Observation

/// Keeps every lecture in `Documents/Lectures/<id>/` as `lecture.json`, `audio.m4a` and
/// `transcript.txt`. The Documents folder is visible in the Files app, so recordings can be
/// copied off the phone without going through the app.
@MainActor
@Observable
final class LectureStore {
    private(set) var lectures: [Lecture] = []

    let rootURL: URL
    @ObservationIgnored private var jobs: [UUID: TranscriptionJob] = [:]

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        rootURL = URL.documentsDirectory.appending(path: "Lectures", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        reload()
    }

    // MARK: Paths

    func folderURL(for id: UUID) -> URL {
        rootURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func audioURL(for id: UUID) -> URL {
        folderURL(for: id).appending(path: "audio.m4a", directoryHint: .notDirectory)
    }

    private func metadataURL(for id: UUID) -> URL {
        folderURL(for: id).appending(path: "lecture.json", directoryHint: .notDirectory)
    }

    func hasAudio(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: id).path(percentEncoded: false))
    }

    // MARK: Reading

    func lecture(id: UUID) -> Lecture? {
        lectures.first { $0.id == id }
    }

    var courses: [String] {
        Array(Set(lectures.map(\.course).filter { !$0.isEmpty })).sorted()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Lecture] = []
        for folder in folders {
            let url = folder.appending(path: "lecture.json", directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url),
                  var lecture = try? Self.decoder.decode(Lecture.self, from: data) else { continue }
            if lecture.isRecording {
                // The app was closed in the middle of a lecture; keep what was saved.
                lecture.isRecording = false
                lecture.duration = max(lecture.duration, lecture.segments.last?.end ?? 0)
                write(lecture)
            }
            loaded.append(lecture)
        }
        lectures = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    func storageUsed() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: Writing

    func save(_ lecture: Lecture) {
        if let index = lectures.firstIndex(where: { $0.id == lecture.id }) {
            lectures[index] = lecture
        } else {
            lectures.append(lecture)
            lectures.sort { $0.createdAt > $1.createdAt }
        }
        write(lecture)
    }

    /// Applies `change` to the latest stored copy of a lecture and saves it.
    func update(_ id: UUID, _ change: (inout Lecture) -> Void) {
        guard var lecture = lecture(id: id) else { return }
        change(&lecture)
        save(lecture)
    }

    func delete(_ id: UUID) {
        jobs[id]?.cancel()
        jobs[id] = nil
        lectures.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folderURL(for: id))
    }

    private func write(_ lecture: Lecture) {
        let folder = folderURL(for: lecture.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(lecture)
            try data.write(to: metadataURL(for: lecture.id), options: .atomic)
            if !lecture.isRecording {
                let text = lecture.exportText(includeTimestamps: true)
                try? text.write(to: folder.appending(path: "transcript.txt"), atomically: true, encoding: .utf8)
            }
        } catch {
            print("LectureStore: couldn't save \(lecture.id): \(error)")
        }
    }

    // MARK: Background transcription jobs

    /// One job per lecture, kept here so progress survives leaving and re-opening the lecture.
    func job(for id: UUID) -> TranscriptionJob {
        if let job = jobs[id] {
            return job
        }
        let job = TranscriptionJob(lectureID: id)
        jobs[id] = job
        return job
    }
}
