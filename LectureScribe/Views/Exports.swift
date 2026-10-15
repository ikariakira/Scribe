import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Shares a transcript as a nicely named .txt file. The text is only built when actually shared.
struct TranscriptExport: Transferable {
    let lecture: Lecture
    let includeTimestamps: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { export in
            let name = Formatters.safeFilename(export.lecture.title)
            let url = FileManager.default.temporaryDirectory.appending(path: "\(name).txt", directoryHint: .notDirectory)
            try export.lecture.exportText(includeTimestamps: export.includeTimestamps)
                .write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

/// Shares a lecture's audio under its title instead of "audio.m4a".
struct AudioExport: Transferable {
    let title: String
    let sourceURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .mpeg4Audio) { export in
            let name = Formatters.safeFilename(export.title)
            let url = FileManager.default.temporaryDirectory.appending(path: "\(name).m4a", directoryHint: .notDirectory)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: export.sourceURL, to: url)
            return SentTransferredFile(url)
        }
    }
}
