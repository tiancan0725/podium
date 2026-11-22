import UIKit
import PDFKit
import PhotosUI

/// A page added in Podium: blank, or a photo. Kept per PDF (by its notes id) and spliced in
/// each time the PDF opens, so the original file is never changed.
struct InsertedPage: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case blank, photo }

    var id = UUID()
    var kind: Kind
    /// The slide it comes after, by its text fingerprint (survives recompiling) and by index as a fallback (-1 = first).
    var afterFingerprint: String?
    var afterSlide: Int
    /// Blank pages: size and background colour, copied from the page they follow.
    var width: Double
    var height: Double
    var background: String = "#FFFFFF"
}

/// A PDF's inserted pages as kept in its companion file, photos (JPEG) included.
struct SavedInserts: Codable, Sendable {
    var updated: Date
    var pages: [InsertedPage]
    /// Page id → JPEG.
    var photos: [String: Data]
}

/// An inserted page with its photo loaded, ready to become a PDF page.
struct LoadedInsert: @unchecked Sendable {
    let record: InsertedPage
    let image: UIImage?

    func makePage() -> PDFPage? {
        switch record.kind {
        case .photo:
            guard let image else { return nil }
            return PDFPage(image: image)
        case .blank:
            let size = CGSize(width: record.width, height: record.height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor(hex: record.background).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            return PDFPage(image: image)
        }
    }
}

/// Inserted pages on disk: `Inserts/<notes id>.json` plus `Inserts/<notes id>/<page id>.jpg` for photos.
enum Inserts {
    private static var directory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Inserts", isDirectory: true)
    }

    static func records(_ id: String) -> [InsertedPage] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")) else { return [] }
        return (try? JSONDecoder().decode([InsertedPage].self, from: data)) ?? []
    }

    /// Records with their photos loaded; safe off the main thread.
    static func load(_ id: String) -> [LoadedInsert] {
        records(id).map { record in
            let image = record.kind == .photo
                ? UIImage(contentsOfFile: directory.appendingPathComponent(id).appendingPathComponent("\(record.id.uuidString).jpg").path)
                : nil
            return LoadedInsert(record: record, image: image)
        }
    }

    /// When this PDF's inserted pages last changed on this iPad (nil if never).
    static func updated(_ id: String) -> Date? {
        let file = directory.appendingPathComponent("\(id).json")
        return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Everything inserted for a PDF, for its companion file (nil if nothing was ever inserted).
    static func saved(_ id: String) -> SavedInserts? {
        guard let updated = updated(id) else { return nil }
        let pages = records(id)
        var photos: [String: Data] = [:]
        for page in pages where page.kind == .photo {
            photos[page.id.uuidString] = try? Data(contentsOf: photoURL(page.id, id: id))
        }
        return SavedInserts(updated: updated, pages: pages, photos: photos)
    }

    /// Takes the companion file's inserted pages when they're newer than this iPad's (say, added on another iPad).
    static func adopt(_ saved: SavedInserts, id: String) {
        guard saved.updated > (updated(id) ?? .distantPast) else { return }
        let old = records(id)
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (pageID, jpeg) in saved.photos {
            try? jpeg.write(to: folder.appendingPathComponent("\(pageID).jpg"), options: .atomic)
        }
        let keep = Set(saved.pages.map(\.id))
        for page in old where !keep.contains(page.id) { deletePhoto(pageID: page.id, id: id) }
        save(saved.pages, id: id)
        // Same date as the companion file, so this iPad doesn't count as newer and write it straight back.
        var file = directory.appendingPathComponent("\(id).json")
        var values = URLResourceValues()
        values.contentModificationDate = saved.updated
        try? file.setResourceValues(values)
    }

    private static func photoURL(_ pageID: UUID, id: String) -> URL {
        directory.appendingPathComponent(id).appendingPathComponent("\(pageID.uuidString).jpg")
    }

    static func save(_ records: [InsertedPage], id: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }

    /// Stores a photo (scaled to at most 2400 px on the long side) for an inserted page.
    static func savePhoto(_ image: UIImage, pageID: UUID, id: String) -> Bool {
        let longSide = max(image.size.width, image.size.height)
        let scale = min(1, 2400 / max(longSide, 1))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return false }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (try? jpeg.write(to: folder.appendingPathComponent("\(pageID.uuidString).jpg"), options: .atomic)) != nil
    }

    static func deletePhoto(pageID: UUID, id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id).appendingPathComponent("\(pageID.uuidString).jpg"))
    }

    /// Everything inserted for a PDF (used when its notes are deleted).
    static func deleteAll(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
    }
}

/// Picks one photo from the library (no photo-library permission needed) and hands back the image.
@MainActor
enum PhotoPicker {
    private static var delegate: Delegate?

    static func present(completion: @escaping (UIImage) -> Void) {
        guard let top = UIApplication.topViewController else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = Delegate(completion: completion)
        picker.delegate = delegate
        Self.delegate = delegate
        top.present(picker, animated: true)
    }

    private final class Delegate: NSObject, PHPickerViewControllerDelegate {
        let completion: (UIImage) -> Void
        init(completion: @escaping (UIImage) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            PhotoPicker.delegate = nil
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            let completion = completion
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                Task { @MainActor in completion(image) }
            }
        }
    }
}
