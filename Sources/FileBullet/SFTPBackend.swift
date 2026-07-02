import Foundation
import Citadel
import NIOCore

@MainActor
final class SFTPBackend: Backend {
    private let config: ConnectionConfig
    private var client: SSHClient?
    private var sftp: SFTPClient?

    init(config: ConnectionConfig) {
        self.config = config
    }

    func connect() async throws {
        let auth: SSHAuthenticationMethod
        if let keyPath = config.keyPath, !keyPath.isEmpty {
            let keyString = try String(contentsOfFile: keyPath, encoding: .utf8)
            auth = try SSHKeyLoader.authentication(username: config.username, keyString: keyString)
        } else {
            auth = .passwordBased(username: config.username, password: config.password)
        }
        let client = try await SSHClient.connect(
            host: config.host,
            port: config.port,
            authenticationMethod: auth,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        self.client = client
        self.sftp = try await client.openSFTP()
    }

    func homeDirectory() async -> String {
        (try? await sftp?.getRealPath(atPath: ".")) ?? "."
    }

    func keepAlive() async throws {
        guard let sftp else { throw BackendError(message: "Not connected") }
        _ = try await sftp.getRealPath(atPath: ".")
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        guard let sftp else { throw BackendError(message: "Not connected") }
        let names = try await sftp.listDirectory(atPath: path)
        return names.flatMap { $0.components }.map { component in
            let parts = component.longname.split(separator: " ", omittingEmptySubsequences: true)
            let (owner, group) = RemoteEntry.ownerGroup(fromListing: parts)
            let isDirectory: Bool
            let isSymlink: Bool
            if let perms = component.attributes.permissions {
                let type = perms & 0o170000
                isDirectory = type == 0o040000
                isSymlink = type == 0o120000
            } else {
                isDirectory = component.longname.first == "d"
                isSymlink = component.longname.first == "l"
            }
            return RemoteEntry(
                name: component.filename,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: component.attributes.size,
                modified: component.attributes.accessModificationTime?.modificationTime,
                owner: owner,
                group: group,
                permissions: component.attributes.permissions.map { $0 & 0o7777 },
                longname: component.longname
            )
        }
    }

    func readFile(_ path: String) async throws -> Data {
        guard let sftp else { throw BackendError(message: "Not connected") }
        let buffer = try await sftp.withFile(filePath: path, flags: .read) { file in
            try await file.readAll()
        }
        return Data(buffer.readableBytesView)
    }

    func writeFile(_ path: String, data: Data, onProgress: (Int) -> Void) async throws {
        guard let sftp else { throw BackendError(message: "Not connected") }
        let handle = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
        do {
            let chunkSize = 256 * 1024
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let end = min(offset + chunkSize, data.count)
                var chunk = ByteBufferAllocator().buffer(capacity: end - offset)
                chunk.writeBytes(data[data.startIndex + offset ..< data.startIndex + end])
                try await handle.write(chunk, at: UInt64(offset))
                onProgress(end - offset)
                offset = end
            }
        } catch {
            try? await handle.close()
            throw error
        }
        try await handle.close()
    }

    func rename(from: String, to: String) async throws {
        guard let sftp else { throw BackendError(message: "Not connected") }
        try await sftp.rename(at: from, to: to)
    }

    func removeFile(_ path: String) async throws {
        guard let sftp else { throw BackendError(message: "Not connected") }
        try await sftp.remove(at: path)
    }

    func removeDirectory(_ path: String) async throws {
        guard let sftp else { throw BackendError(message: "Not connected") }
        try await sftp.rmdir(at: path)
    }

    func makeDirectory(_ path: String) async throws {
        guard let sftp else { throw BackendError(message: "Not connected") }
        try await sftp.createDirectory(atPath: path)
    }

    func setPermissions(_ path: String, mode: UInt32) async throws {
        guard let sftp else { throw BackendError(message: "Not connected") }
        var attributes = SFTPFileAttributes()
        attributes.permissions = mode
        try await sftp.setAttributes(at: path, to: attributes)
    }

    func setOwner(_ path: String, owner: String, group: String?) async throws {
        guard let client else { throw BackendError(message: "Not connected") }
        let spec = group.map { "\(owner):\($0)" } ?? owner
        let command = "chown \(shellQuote(spec)) -- \(shellQuote(path))"
        _ = try await client.executeCommand(command, mergeStreams: true)
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func serverCopy(from: String, to: String) async -> Bool {
        guard let client else { return false }
        let command = "cp -a -- \(shellQuote(from)) \(shellQuote(to))"
        do {
            _ = try await client.executeCommand(command, mergeStreams: true)
            return true
        } catch {
            return false   // no cp / failed → caller falls back to read+write
        }
    }

    let supportsShell = true

    func runShell(_ command: String, in directory: String) async throws -> String {
        guard let client else { throw BackendError(message: "Not connected") }
        let full = "cd \(shellQuote(directory)) 2>/dev/null; \(command)"
        let buffer = try await client.executeCommand(full, mergeStreams: true, inShell: true)
        return String(decoding: buffer.readableBytesView, as: UTF8.self)
    }

    @available(macOS 15.0, *)
    func makeTerminalHost() -> TerminalHost? {
        guard let client else { return nil }
        return TerminalHost(client: client)
    }

    func disconnect() async {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
    }
}
