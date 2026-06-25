import Foundation

/// One entry in a remote directory listing. Backend-agnostic.
struct RemoteEntry: Identifiable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64?
    let longname: String
    /// POSIX permission bits (incl. setuid/setgid/sticky), if known.
    let permissions: UInt32?
    let modified: Date?
    let owner: String?
    let group: String?

    init(name: String,
         isDirectory: Bool,
         isSymlink: Bool = false,
         size: UInt64? = nil,
         modified: Date? = nil,
         owner: String? = nil,
         group: String? = nil,
         permissions: UInt32? = nil,
         longname: String = "") {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
        self.owner = owner
        self.group = group
        self.permissions = permissions
        self.longname = longname
    }

    /// Parse owner/group from an `ls -l` style line ("perms links owner group …").
    static func ownerGroup(fromListing parts: [Substring]) -> (String?, String?) {
        guard parts.count >= 4, parts[0].count >= 10 else { return (nil, nil) }
        return (String(parts[2]), String(parts[3]))
    }

    /// Convert an `ls -l` permission string ("rwxr-xr-x") into mode bits.
    static func permissions(fromLsString perms: String) -> UInt32? {
        let chars = Array(perms)
        guard chars.count >= 10 else { return nil }
        var mode: UInt32 = 0
        let bits: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        for (i, bit) in bits.enumerated() where chars[i + 1] != "-" {
            mode |= bit
        }
        return mode
    }

    var displaySize: String {
        guard !isDirectory, let size else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var displayDate: String {
        guard let modified else { return "" }
        return RemoteEntry.dateFormatter.string(from: modified)
    }

    var displayOwner: String { owner ?? "" }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy HH:mm"
        return f
    }()

    var icon: String {
        if isDirectory { return "folder.fill" }
        if isSymlink { return "arrow.up.right.square" }
        return "doc.text"
    }
}

/// Sync lifecycle of a file we downloaded and handed off to an external editor.
enum SyncState: Equatable {
    case synced
    case uploading
    case error(String)
}

/// A remote file currently being edited locally. We poll its local copy and
/// push changes back to the server whenever the editor saves it.
struct OpenFile: Identifiable {
    let id = UUID()
    let remotePath: String
    let localURL: URL
    var lastModified: Date
    var state: SyncState = .synced
    var lastSyncedAt: Date?

    var name: String { localURL.lastPathComponent }
}

/// Join a remote POSIX path with a child component.
func remoteJoin(_ base: String, _ component: String) -> String {
    if base.isEmpty || base == "." { return component }
    if base == "/" { return "/" + component }
    return base.hasSuffix("/") ? base + component : base + "/" + component
}

/// Parent of a remote POSIX path.
func remoteParent(_ path: String) -> String {
    let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    guard let slash = trimmed.lastIndex(of: "/") else { return "." }
    if slash == trimmed.startIndex { return "/" }
    return String(trimmed[trimmed.startIndex..<slash])
}
