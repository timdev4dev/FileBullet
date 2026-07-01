import Foundation

enum TransferProtocol: String, Codable {
    case sftp
    case ftp

    var label: String {
        switch self {
        case .sftp: return "SFTP"
        case .ftp: return "FTP"
        }
    }
    var defaultPort: Int { self == .sftp ? 22 : 21 }
}

struct ConnectionConfig {
    var proto: TransferProtocol
    var host: String
    var port: Int
    var username: String
    var password: String
    var keyPath: String?
}

/// A remote file-transfer backend. Runs on the main actor so view-model state
/// updates (e.g. progress callbacks) stay on the main thread.
@MainActor
protocol Backend: AnyObject {
    func connect() async throws
    func homeDirectory() async -> String
    /// Lightweight no-op to keep an idle connection alive; throws if the link is dead.
    func keepAlive() async throws
    func list(_ path: String) async throws -> [RemoteEntry]
    func readFile(_ path: String) async throws -> Data
    /// Writes `data` to `path`. `onProgress` receives byte deltas as they upload.
    /// Honour Task cancellation for mid-transfer abort.
    func writeFile(_ path: String, data: Data, onProgress: (Int) -> Void) async throws
    func rename(from: String, to: String) async throws
    func removeFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func makeDirectory(_ path: String) async throws
    func setPermissions(_ path: String, mode: UInt32) async throws
    func setOwner(_ path: String, owner: String, group: String?) async throws
    /// Server-side copy if supported (e.g. `cp` over SSH). Returns false if the
    /// caller should fall back to a download+upload copy.
    func serverCopy(from: String, to: String) async -> Bool
    /// Whether an interactive shell is available (SSH yes, FTP no).
    var supportsShell: Bool { get }
    /// Run a shell command in `directory`, returning combined stdout/stderr.
    func runShell(_ command: String, in directory: String) async throws -> String
    func disconnect() async
}

@MainActor
func makeBackend(_ config: ConnectionConfig) -> Backend {
    switch config.proto {
    case .sftp: return SFTPBackend(config: config)
    case .ftp:  return FTPBackend(config: config)
    }
}

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
