import Foundation

/// What kind of data a file is, for the colored bar and the drill-down.
public enum StorageCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case apps, photos, videos, music, documents, archives, developer, caches, backups, trash, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apps: "Apps"
        case .photos: "Photos"
        case .videos: "Movies & Videos"
        case .music: "Music & Audio"
        case .documents: "Documents"
        case .archives: "Archives & Installers"
        case .developer: "Developer"
        case .caches: "Caches & Logs"
        case .backups: "Device Backups"
        case .trash: "Trash"
        case .other: "Other Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .apps: "app.badge"
        case .photos: "photo"
        case .videos: "film"
        case .music: "music.note"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .developer: "hammer"
        case .caches: "clock.arrow.circlepath"
        case .backups: "iphone"
        case .trash: "trash"
        case .other: "questionmark.folder"
        }
    }
}

public enum Classifier {
    /// Sorts a file into a category, first by where it is (apps, caches, Trash), then by its extension.
    public static func category(forPath path: String) -> StorageCategory {
        let lower = path.lowercased()
        if lower.contains("/.trash/") || lower.contains("/.trashes/") { return .trash }
        if lower.contains("/library/developer/") || lower.contains("/node_modules/") || lower.contains("/deriveddata/")
            || lower.contains("/.gradle/") || lower.contains("/.cargo/") { return .developer }
        if lower.contains("/mobilesync/backup/") { return .backups }
        if lower.contains(".app/") { return .apps }
        if lower.contains("/library/caches/") || lower.contains("/.cache/") || lower.contains("/library/logs/") {
            return .caches
        }
        if lower.contains(".photoslibrary/") { return .photos }
        let ext = (lower as NSString).pathExtension
        return byExtension[ext] ?? .other
    }

    static let byExtension: [String: StorageCategory] = {
        var map: [String: StorageCategory] = [:]
        let groups: [StorageCategory: [String]] = [
            .photos: ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "raw", "cr2", "cr3", "nef", "arw",
                      "dng", "orf", "rw2", "raf", "webp", "bmp", "psd", "svg"],
            .videos: ["mov", "mp4", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "mts", "m2ts", "3gp",
                      "braw", "r3d", "ts", "vob", "fcpbundle"],
            .music: ["mp3", "m4a", "aac", "flac", "alac", "wav", "aif", "aiff", "ogg", "opus", "wma", "dsf", "dff",
                     "ape", "mid", "midi", "logicx", "band"],
            .documents: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf",
                         "md", "csv", "epub", "odt", "ods", "odp"],
            .archives: ["zip", "dmg", "pkg", "iso", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "sparseimage",
                        "sparsebundle", "img", "ipsw", "xip"],
            .developer: ["o", "a", "dylib", "swiftmodule", "pyc", "class", "jar"],
        ]
        for (category, extensions) in groups {
            for ext in extensions { map[ext] = category }
        }
        return map
    }()
}
