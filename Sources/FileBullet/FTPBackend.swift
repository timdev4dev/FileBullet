import Foundation

/// Plain FTP backend implemented on top of the system `curl` binary.
@MainActor
final class FTPBackend: Backend {
    private let config: ConnectionConfig
    private let curl = "/usr/bin/curl"

    init(config: ConnectionConfig) {
        self.config = config
    }

    // MARK: Backend

    func connect() async throws {
        // Validate credentials by listing the start directory.
        _ = try await runCurl(["--list-only", url(for: "/", isDirectory: true)])
    }

    func homeDirectory() async -> String { "/" }

    // FTP opens a fresh curl connection per command, so nothing to keep alive.
    func keepAlive() async throws {}

    func list(_ path: String) async throws -> [RemoteEntry] {
        let output = try await runCurl([url(for: path, isDirectory: true)])
        let text = String(decoding: output, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap(parseListingLine)
    }

    func readFile(_ path: String) async throws -> Data {
        try await runCurl([url(for: path, isDirectory: false)])
    }

    func writeFile(_ path: String, data: Data, onProgress: (Int) -> Void) async throws {
        try Task.checkCancellation()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("fb-upload-\(UUID().uuidString)")
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await runCurl([
            "--ftp-create-dirs",
            "--upload-file", temp.path,
            url(for: path, isDirectory: false),
        ])
        onProgress(data.count)
    }

    func rename(from: String, to: String) async throws {
        try await runQuote(["RNFR \(from)", "RNTO \(to)"], near: from)
    }

    func removeFile(_ path: String) async throws {
        try await runQuote(["DELE \(path)"], near: path)
    }

    func removeDirectory(_ path: String) async throws {
        try await runQuote(["RMD \(path)"], near: path)
    }

    func makeDirectory(_ path: String) async throws {
        try await runQuote(["MKD \(path)"], near: path)
    }

    func setPermissions(_ path: String, mode: UInt32) async throws {
        try await runQuote(["SITE CHMOD \(String(mode, radix: 8)) \(path)"], near: path)
    }

    func disconnect() async {}

    // MARK: URLs

    private func url(for path: String, isDirectory: Bool) -> String {
        var p = path.hasPrefix("/") ? path : "/" + path
        if isDirectory, !p.hasSuffix("/") { p += "/" }
        let encoded = p.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p
        return "ftp://\(config.host):\(config.port)\(encoded)"
    }

    /// Run FTP quote commands. `near` directory is used as the transfer URL so
    /// the user only needs access to the relevant folder.
    private func runQuote(_ commands: [String], near path: String) async throws {
        let dir = remoteParent(path)
        var args = ["--output", "/dev/null"]
        for command in commands { args += ["--quote", command] }
        args.append(url(for: dir, isDirectory: true))
        _ = try await runCurl(args)
    }

    // MARK: curl runner

    private func runCurl(_ args: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: curl)
        process.arguments = [
            "--silent", "--show-error", "--connect-timeout", "20",
            "--user", "\(config.username):\(config.password)",
        ] + args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain pipes concurrently to avoid deadlock on large output.
        let outActor = DataSink()
        let errActor = DataSink()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { Task { await outActor.append(d) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { Task { await errActor.append(d) } }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // Give the sinks a moment to flush any tail data.
        let out = await outActor.drain(remaining: outPipe.fileHandleForReading)
        let err = await errActor.drain(remaining: errPipe.fileHandleForReading)

        if Task.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BackendError(message: message.isEmpty
                ? "curl exited with code \(process.terminationStatus)" : message)
        }
        return out
    }

    // MARK: Listing parser

    private func parseListingLine(_ line: Substring) -> RemoteEntry? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 9, parts[0].count >= 10 else { return nil }
        let perms = String(parts[0])
        let typeChar = perms.first
        let isDirectory = typeChar == "d"
        let isSymlink = typeChar == "l"

        var nameParts = parts[8...].joined(separator: " ")
        if isSymlink, let arrow = nameParts.range(of: " -> ") {
            nameParts = String(nameParts[..<arrow.lowerBound])
        }
        let name = nameParts
        if name == "." || name == ".." || name.isEmpty { return nil }

        let (owner, group) = RemoteEntry.ownerGroup(fromListing: parts)
        let size = isDirectory ? nil : UInt64(parts[4])
        let modified = parseDate(month: parts[5], day: parts[6], yearOrTime: parts[7])

        return RemoteEntry(
            name: name,
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            size: size,
            modified: modified,
            owner: owner,
            group: group,
            permissions: RemoteEntry.permissions(fromLsString: perms),
            longname: String(line)
        )
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun",
                                 "jul", "aug", "sep", "oct", "nov", "dec"]

    private func parseDate(month: Substring, day: Substring, yearOrTime: Substring) -> Date? {
        guard let m = FTPBackend.months.firstIndex(of: month.lowercased()),
              let d = Int(day) else { return nil }
        var comps = DateComponents()
        comps.month = m + 1
        comps.day = d
        if yearOrTime.contains(":") {
            let hm = yearOrTime.split(separator: ":")
            comps.hour = hm.first.flatMap { Int($0) }
            comps.minute = hm.count > 1 ? Int(hm[1]) : 0
            // No year in listing → assume current year.
            comps.year = Calendar.current.component(.year, from: Date())
        } else {
            comps.year = Int(yearOrTime)
        }
        return Calendar.current.date(from: comps)
    }
}

/// Actor that accumulates streamed process output safely.
private actor DataSink {
    private var data = Data()
    func append(_ chunk: Data) { data.append(chunk) }
    func drain(remaining handle: FileHandle) -> Data {
        if let tail = try? handle.readToEnd(), !tail.isEmpty { data.append(tail) }
        return data
    }
}
