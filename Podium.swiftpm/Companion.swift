import Foundation

/// Optional copy of a PDF's ink and prep notes in a small file next to the PDF ("lecture05.podium"),
/// so notes sync with Dropbox or iCloud, survive deleting the app, and appear on other iPads.
/// Only for PDFs in linked folders: a single added PDF doesn't give Podium access to its folder.
struct CompanionFile: Codable {
    var version = 1
    var updated: Date
    var title: String
    var ink: SavedNotes?
    var prep: SavedPrep?
    /// Pages added in Podium, photos included.
    var inserts: SavedInserts?
}

/// Where a deck's companion file lives, and the security-scoped folder that lets Podium write it.
struct CompanionTarget: Sendable {
    let url: URL
    let scope: URL
}

enum Companion {
    static let defaultsKey = "companion.enabled"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// "lecture05.pdf" → "lecture05.podium", in the same folder.
    static func url(for pdf: URL) -> URL {
        pdf.deletingPathExtension().appendingPathExtension("podium")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads the companion file (downloading it if the cloud app hasn't yet). Call off the main thread.
    static func read(_ target: CompanionTarget) -> CompanionFile? {
        let accessing = target.scope.startAccessingSecurityScopedResource()
        defer { if accessing { target.scope.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: target.url, options: [], error: &error) { url in
            data = try? Data(contentsOf: url)
        }
        return data.flatMap { try? decoder.decode(CompanionFile.self, from: $0) }
    }

    /// Writes the file, or removes it when there's nothing left in it. Call off the main thread;
    /// writes happen in the order they're made (the notes save queue).
    static func write(_ file: CompanionFile, to target: CompanionTarget) {
        let empty = (file.ink?.records.isEmpty ?? true) && (file.prep?.notes.isEmpty ?? true)
            && (file.inserts?.pages.isEmpty ?? true)
        let data = empty ? nil : try? encoder.encode(file)
        let accessing = target.scope.startAccessingSecurityScopedResource()
        defer { if accessing { target.scope.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        if let data {
            NSFileCoordinator().coordinate(writingItemAt: target.url, options: [.forReplacing], error: &error) { url in
                try? data.write(to: url, options: .atomic)
            }
        } else if FileManager.default.fileExists(atPath: target.url.path) {
            NSFileCoordinator().coordinate(writingItemAt: target.url, options: [.forDeleting], error: &error) { url in
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// "Clear Notes" from the library: drop the ink from the companion file, keep the prep notes.
    static func clearInk(_ target: CompanionTarget) {
        DocumentState.saveQueue.async {
            guard var file = read(target) else { return }
            file.ink = nil
            file.updated = .now
            write(file, to: target)
        }
    }
}
