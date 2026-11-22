import Foundation
import CryptoKit
import PencilKit

/// Ink saved per PDF in Application Support, so notes survive closing the deck and
/// restarting the app until they're cleared on purpose.
///
/// A document is identified by its file path, not its bytes, so recompiling keeps the notes.
/// Each slide's ink is stored with the slide's text fingerprint, so frames added or removed
/// when recompiling don't shift notes onto the wrong slides.
struct SavedNotes: Codable {
    struct Record: Codable {
        var fingerprint: String?
        var slide: Int?
        var step: Int?             // set when the ink belongs to one overlay step only
        var board: Bool?
        var drawing: Data
    }

    var title: String
    var records: [Record]
    var updated: Date?             // when the ink last changed; the newer copy wins on open
}

enum Notes {
    /// Stable id for a PDF, from its normalised path.
    static func id(for url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Notes", isDirectory: true)
    }

    private static func file(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    static func exists(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: file(id).path)
    }

    static func load(_ id: String) -> SavedNotes? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(SavedNotes.self, from: data)
    }

    /// Writes the notes, or deletes the file when there's nothing left to keep.
    static func save(_ notes: SavedNotes, id: String) {
        guard !notes.records.isEmpty else {
            delete(id)
            return
        }
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(id), options: .atomic)
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
    }

    // MARK: Converting between saved records and in-memory ink keys

    /// In-memory keys are "s<slide>", "p<page>" and the whiteboard's key.
    static func records(from drawings: [String: PKDrawing], deck: Deck) -> [SavedNotes.Record] {
        drawings.compactMap { key, drawing in
            guard !drawing.strokes.isEmpty else { return nil }
            let data = drawing.dataRepresentation()
            if key == PresentationState.boardKey {
                return SavedNotes.Record(board: true, drawing: data)
            }
            guard let number = Int(key.dropFirst()) else { return nil }
            switch key.first {
            case "s" where deck.slides.indices.contains(number):
                return SavedNotes.Record(fingerprint: deck.fingerprints[number], slide: number, drawing: data)
            case "p" where (0..<deck.pageCount).contains(number):
                let slide = deck.slide(ofPage: number)
                return SavedNotes.Record(fingerprint: deck.fingerprints[slide.id], slide: slide.id,
                                         step: number - slide.pages.lowerBound, drawing: data)
            default:
                return nil
            }
        }
    }

    /// Places saved ink back on the deck. Records whose slide can't be found are returned
    /// as orphans so they can be written back instead of being lost.
    static func drawings(from records: [SavedNotes.Record], deck: Deck)
        -> (drawings: [String: PKDrawing], orphans: [SavedNotes.Record]) {
        var indexOfFingerprint: [String: Int] = [:]
        for (index, fingerprint) in deck.fingerprints.enumerated() { indexOfFingerprint[fingerprint] = index }
        let matchedSlides = Set(records.compactMap { $0.fingerprint.flatMap { indexOfFingerprint[$0] } })

        var drawings: [String: PKDrawing] = [:]
        var orphans: [SavedNotes.Record] = []
        for record in records {
            guard let drawing = try? PKDrawing(data: record.drawing) else { continue }
            if record.board == true {
                drawings[PresentationState.boardKey] = drawing
                continue
            }
            // Prefer the slide with the same text; fall back to the same position if that slide
            // isn't claimed by another record's text.
            var slideIndex = record.fingerprint.flatMap { indexOfFingerprint[$0] }
            if slideIndex == nil, let saved = record.slide, deck.slides.indices.contains(saved),
               !matchedSlides.contains(saved) {
                slideIndex = saved
            }
            guard let slideIndex else {
                orphans.append(record)
                continue
            }
            let slide = deck.slides[slideIndex]
            if let step = record.step {
                let page = slide.pages.lowerBound + step
                guard slide.pages.contains(page) else {
                    orphans.append(record)
                    continue
                }
                drawings["p\(page)"] = drawing
            } else {
                drawings["s\(slideIndex)"] = drawing
            }
        }
        return (drawings, orphans)
    }
}
