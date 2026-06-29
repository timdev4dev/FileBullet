import Foundation
import AppKit

/// Owns one connection (SFTP or FTP) and drives all remote operations through a
/// `Backend`. Lives on the main actor so SwiftUI views bind to it directly.
@MainActor
final class SFTPManager: ObservableObject, Identifiable {
    let id = UUID()

    @Published var isConnected = false
    @Published var isBusy = false
    @Published var status = ""
    @Published var currentPath = "."
    @Published var connectedHost = ""
    @Published var entries: [RemoteEntry] = []
    @Published var openFiles: [OpenFile] = []
    @Published var selectedEntryIDs: Set<RemoteEntry.ID> = []

    // Drag & drop upload progress (byte-level).
    @Published var uploadInProgress = false
    @Published var uploadTotalBytes: Int64 = 0
    @Published var uploadDoneBytes: Int64 = 0
    @Published var uploadFilesTotal = 0
    @Published var uploadFilesDone = 0
    @Published var uploadCurrentName = ""
    @Published private(set) var tabTitle = loc("New connection", "Новое подключение", "Neue Verbindung", "Nueva conexión")

    // Draft connection form fields (kept here so the tab preserves them).
    @Published var draftProto: TransferProtocol = .sftp
    @Published var draftHost = ""
    @Published var draftPort = "22"
    @Published var draftUser = ""
    @Published var draftPassword = ""
    @Published var draftKeyPath = ""

    private var backend: Backend?
    private var config: ConnectionConfig?
    private var pollTimer: Timer?
    private var keepAliveTimer: Timer?
    private var uploadTask: Task<Void, Never>?

    /// Per-connection cache subfolder so tabs don't clobber each other's files.
    private var cacheDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FileBullet/\(id.uuidString)", isDirectory: true)
    }

    // MARK: - Connection

    func connect(proto: TransferProtocol, host: String, port: Int,
                 username: String, password: String, keyPath: String?) async {
        guard !host.isEmpty, !username.isEmpty else {
            status = loc("Enter host and username.", "Укажите хост и имя пользователя.", "Host und Benutzername eingeben.", "Introduce el host y el usuario.")
            return
        }
        isBusy = true
        tabTitle = "\(username)@\(host)"
        status = loc("Connecting to \(host):\(port)…", "Подключение к \(host):\(port)…", "Verbinde mit \(host):\(port)…", "Conectando a \(host):\(port)…")
        do {
            let config = ConnectionConfig(proto: proto, host: host, port: port,
                                          username: username, password: password, keyPath: keyPath)
            let backend = makeBackend(config)
            try await backend.connect()
            self.backend = backend
            self.config = config
            self.isConnected = true
            self.connectedHost = host
            startKeepAlive()

            let home = await backend.homeDirectory()
            await list(path: home)
            status = loc("Connected to \(host).", "Подключено к \(host).", "Verbunden mit \(host).", "Conectado a \(host).")
        } catch {
            status = loc("Connection error: \(humanReadable(error))", "Ошибка подключения: \(humanReadable(error))", "Verbindungsfehler: \(humanReadable(error))", "Error de conexión: \(humanReadable(error))")
        }
        isBusy = false
    }

    func disconnect() async {
        pollTimer?.invalidate()
        pollTimer = nil
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        await backend?.disconnect()
        backend = nil
        config = nil
        isConnected = false
        entries = []
        openFiles = []
        selectedEntryIDs = []
        currentPath = "."
        connectedHost = ""
        tabTitle = loc("New connection", "Новое подключение", "Neue Verbindung", "Nueva conexión")
        status = loc("Disconnected.", "Отключено.", "Getrennt.", "Desconectado.")
    }

    // MARK: - Browsing

    func list(path: String) async {
        guard backend != nil else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await loadEntries(path)
        } catch {
            // The connection may have been dropped on idle — reconnect and retry once.
            if isConnectionError(error), await reconnect() {
                do {
                    try await loadEntries(path)
                    return
                } catch {
                    status = loc("Couldn't read \(path): \(humanReadable(error))", "Не удалось прочитать \(path): \(humanReadable(error))", "Konnte \(path) nicht lesen: \(humanReadable(error))", "No se pudo leer \(path): \(humanReadable(error))")
                }
            } else {
                status = loc("Couldn't read \(path): \(humanReadable(error))", "Не удалось прочитать \(path): \(humanReadable(error))", "Konnte \(path) nicht lesen: \(humanReadable(error))", "No se pudo leer \(path): \(humanReadable(error))")
            }
        }
    }

    private func loadEntries(_ path: String) async throws {
        guard let backend else { throw BackendError(message: "Not connected") }
        var items = try await backend.list(path)
            .filter { $0.name != "." && $0.name != ".." }
        items.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        self.currentPath = path
        self.entries = items
        self.selectedEntryIDs = []
    }

    // MARK: - Keep-alive & reconnect

    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.keepAlivePing() }
        }
    }

    private func keepAlivePing() async {
        guard isConnected, !isBusy, !uploadInProgress, let backend else { return }
        do {
            try await backend.keepAlive()
        } catch {
            // Idle drop — re-establish quietly so the next action just works.
            _ = await reconnect()
        }
    }

    /// Rebuild the backend from the stored config, keeping the current folder.
    @discardableResult
    private func reconnect() async -> Bool {
        guard let config else { return false }
        await backend?.disconnect()
        backend = nil
        do {
            let fresh = makeBackend(config)
            try await fresh.connect()
            backend = fresh
            isConnected = true
            return true
        } catch {
            isConnected = false
            status = loc("Connection lost — reconnect failed.", "Соединение потеряно — переподключение не удалось.", "Verbindung verloren — erneut fehlgeschlagen.", "Conexión perdida — fallo al reconectar.")
            return false
        }
    }

    private func isConnectionError(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        for marker in ["closed", "channel", "eof", "broken", "reset",
                       "not connected", "notconnected", "timed out", "connection"] {
            if text.contains(marker) { return true }
        }
        return false
    }

    func refresh() async {
        await list(path: currentPath)
    }

    func open(_ entry: RemoteEntry) {
        if entry.isDirectory {
            Task { await list(path: remoteJoin(currentPath, entry.name)) }
        } else {
            Task { await openFile(entry, withApp: nil) }
        }
    }

    func open(_ entry: RemoteEntry, withApp appURL: URL?) {
        guard !entry.isDirectory else { return }
        Task { await openFile(entry, withApp: appURL) }
    }

    func goUp() {
        Task { await list(path: remoteParent(currentPath)) }
    }

    func go(to path: String) {
        Task { await list(path: path) }
    }

    // MARK: - Edit flow (download → external editor → upload on save)

    private func openFile(_ entry: RemoteEntry, withApp appURL: URL?) async {
        guard let backend else { return }
        let remotePath = remoteJoin(currentPath, entry.name)
        isBusy = true
        do {
            let data = try await backend.readFile(remotePath)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let localURL = cacheDir.appendingPathComponent(entry.name)
            try data.write(to: localURL)

            let mtime = modificationDate(of: localURL) ?? Date()
            openFiles.removeAll { $0.remotePath == remotePath }
            openFiles.append(OpenFile(remotePath: remotePath, localURL: localURL, lastModified: mtime))

            if let appURL {
                _ = try await NSWorkspace.shared.open([localURL], withApplicationAt: appURL,
                                                      configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(localURL)
            }
            startPolling()
            status = loc("Opened \(entry.name) in external editor.", "Открыт \(entry.name) во внешнем редакторе.", "\(entry.name) im externen Editor geöffnet.", "Abierto \(entry.name) en editor externo.")
        } catch {
            status = loc("Couldn't open \(entry.name): \(humanReadable(error))", "Не удалось открыть \(entry.name): \(humanReadable(error))", "Konnte \(entry.name) nicht öffnen: \(humanReadable(error))", "No se pudo abrir \(entry.name): \(humanReadable(error))")
        }
        isBusy = false
    }

    // MARK: - File operations (rename / delete / duplicate)

    func rename(_ entry: RemoteEntry, to newName: String) async {
        guard let backend else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name, !trimmed.contains("/") else { return }
        let from = remoteJoin(currentPath, entry.name)
        let to = remoteJoin(currentPath, trimmed)
        do {
            try await backend.rename(from: from, to: to)
            status = loc("Renamed: \(entry.name) → \(trimmed)", "Переименовано: \(entry.name) → \(trimmed)", "Umbenannt: \(entry.name) → \(trimmed)", "Renombrado: \(entry.name) → \(trimmed)")
            await refresh()
        } catch {
            status = loc("Rename error: \(humanReadable(error))", "Ошибка переименования: \(humanReadable(error))", "Fehler beim Umbenennen: \(humanReadable(error))", "Error al renombrar: \(humanReadable(error))")
        }
    }

    func createFolder(_ name: String) async {
        guard let backend else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        do {
            try await backend.makeDirectory(remoteJoin(currentPath, trimmed))
            status = loc("Folder created: \(trimmed)", "Папка создана: \(trimmed)", "Ordner erstellt: \(trimmed)", "Carpeta creada: \(trimmed)")
            await refresh()
        } catch {
            status = loc("Couldn't create folder: \(humanReadable(error))", "Не удалось создать папку: \(humanReadable(error))", "Ordner-Fehler: \(humanReadable(error))", "Error al crear carpeta: \(humanReadable(error))")
        }
    }

    func createFile(_ name: String) async {
        guard let backend else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else { return }
        do {
            try await backend.writeFile(remoteJoin(currentPath, trimmed), data: Data(), onProgress: { _ in })
            status = loc("File created: \(trimmed)", "Файл создан: \(trimmed)", "Datei erstellt: \(trimmed)", "Archivo creado: \(trimmed)")
            await refresh()
        } catch {
            status = loc("Couldn't create file: \(humanReadable(error))", "Не удалось создать файл: \(humanReadable(error))", "Datei-Fehler: \(humanReadable(error))", "Error al crear archivo: \(humanReadable(error))")
        }
    }

    func applyAttributes(_ entry: RemoteEntry, mode: UInt32, owner: String, group: String) async {
        guard let backend else { return }
        let path = remoteJoin(currentPath, entry.name)
        let newOwner = owner.trimmingCharacters(in: .whitespaces)
        let newGroup = group.trimmingCharacters(in: .whitespaces)
        let ownerChanged = !newOwner.isEmpty &&
            (newOwner != (entry.owner ?? "") || newGroup != (entry.group ?? ""))
        let modeChanged = mode != (entry.permissions ?? 0)
        do {
            if modeChanged {
                try await backend.setPermissions(path, mode: mode)
            }
            if ownerChanged {
                try await backend.setOwner(path, owner: newOwner, group: newGroup.isEmpty ? nil : newGroup)
            }
            if modeChanged || ownerChanged {
                status = loc("Updated \(entry.name)", "Обновлено: \(entry.name)", "Aktualisiert: \(entry.name)", "Actualizado: \(entry.name)")
                await refresh()
            }
        } catch {
            status = loc("Attributes error: \(humanReadable(error))", "Ошибка атрибутов: \(humanReadable(error))", "Attribut-Fehler: \(humanReadable(error))", "Error de atributos: \(humanReadable(error))")
        }
    }

    func deleteMany(_ entries: [RemoteEntry]) async {
        guard backend != nil, !entries.isEmpty else { return }
        isBusy = true
        var deleted = 0
        do {
            for entry in entries {
                let path = remoteJoin(currentPath, entry.name)
                try await remove(path: path, isDirectory: entry.isDirectory)
                openFiles.removeAll { $0.remotePath == path }
                deleted += 1
            }
            status = loc("Deleted \(deleted) item(s)", "Удалено объектов: \(deleted)", "Gelöscht: \(deleted)", "Eliminados: \(deleted)")
            await refresh()
        } catch {
            status = loc("Delete error: \(humanReadable(error))", "Ошибка удаления: \(humanReadable(error))", "Fehler beim Löschen: \(humanReadable(error))", "Error al eliminar: \(humanReadable(error))")
        }
        isBusy = false
    }

    func downloadMany(_ entries: [RemoteEntry]) {
        if entries.count == 1 {
            Task { await downloadEntry(entries[0]) }
        } else {
            Task { await downloadInto(entries) }
        }
    }

    private func downloadInto(_ entries: [RemoteEntry]) async {
        guard let backend, !entries.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = loc("Download here", "Скачать сюда", "Hierher laden", "Descargar aquí")
        panel.message = loc("Choose a folder for \(entries.count) items", "Выберите папку для \(entries.count) объектов", "Ordner für \(entries.count) Objekte wählen", "Carpeta para \(entries.count) elementos")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        isBusy = true
        do {
            for entry in entries {
                let remotePath = remoteJoin(currentPath, entry.name)
                let dest = dir.appendingPathComponent(entry.name)
                if entry.isDirectory {
                    try await downloadDirectory(remotePath, to: dest)
                } else {
                    let data = try await backend.readFile(remotePath)
                    try data.write(to: dest)
                }
            }
            status = loc("Downloaded \(entries.count) item(s)", "Скачано объектов: \(entries.count)", "Geladen: \(entries.count)", "Descargados: \(entries.count)")
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } catch {
            status = loc("Download error: \(humanReadable(error))", "Ошибка скачивания: \(humanReadable(error))", "Download-Fehler: \(humanReadable(error))", "Error de descarga: \(humanReadable(error))")
        }
        isBusy = false
    }

    func delete(_ entry: RemoteEntry) async {
        guard backend != nil else { return }
        let path = remoteJoin(currentPath, entry.name)
        isBusy = true
        do {
            try await remove(path: path, isDirectory: entry.isDirectory)
            openFiles.removeAll { $0.remotePath == path }
            status = loc("Deleted: \(entry.name)", "Удалено: \(entry.name)", "Gelöscht: \(entry.name)", "Eliminado: \(entry.name)")
            await refresh()
        } catch {
            status = loc("Delete error: \(humanReadable(error))", "Ошибка удаления: \(humanReadable(error))", "Fehler beim Löschen: \(humanReadable(error))", "Error al eliminar: \(humanReadable(error))")
        }
        isBusy = false
    }

    func duplicate(_ entry: RemoteEntry) async {
        guard backend != nil else { return }
        let source = remoteJoin(currentPath, entry.name)
        let destName = duplicateName(for: entry.name, isDirectory: entry.isDirectory)
        let dest = remoteJoin(currentPath, destName)
        isBusy = true
        do {
            try await copy(from: source, to: dest, isDirectory: entry.isDirectory)
            status = loc("Copy created: \(destName)", "Создана копия: \(destName)", "Kopie erstellt: \(destName)", "Copia creada: \(destName)")
            await refresh()
        } catch {
            status = loc("Duplicate error: \(humanReadable(error))", "Ошибка дублирования: \(humanReadable(error))", "Fehler beim Duplizieren: \(humanReadable(error))", "Error al duplicar: \(humanReadable(error))")
        }
        isBusy = false
    }

    private func remove(path: String, isDirectory: Bool) async throws {
        guard let backend else { return }
        if isDirectory {
            for child in try await children(of: path) {
                try await remove(path: remoteJoin(path, child.name), isDirectory: child.isDir)
            }
            try await backend.removeDirectory(path)
        } else {
            try await backend.removeFile(path)
        }
    }

    private func copy(from: String, to: String, isDirectory: Bool) async throws {
        guard let backend else { return }
        if isDirectory {
            try await backend.makeDirectory(to)
            for child in try await children(of: from) {
                try await copy(from: remoteJoin(from, child.name),
                               to: remoteJoin(to, child.name),
                               isDirectory: child.isDir)
            }
        } else {
            let data = try await backend.readFile(from)
            try await backend.writeFile(to, data: data, onProgress: { _ in })
        }
    }

    /// Real child entries of a directory (name + isDir), excluding . and ..
    private func children(of path: String) async throws -> [(name: String, isDir: Bool)] {
        guard let backend else { return [] }
        return try await backend.list(path)
            .filter { $0.name != "." && $0.name != ".." }
            .map { ($0.name, $0.isDirectory) }
    }

    private func duplicateName(for name: String, isDirectory: Bool) -> String {
        guard !isDirectory else { return name + " copy" }
        let ns = name as NSString
        let ext = ns.pathExtension
        guard !ext.isEmpty else { return name + " copy" }
        return "\(ns.deletingPathExtension) copy.\(ext)"
    }

    // MARK: - Download

    func download(_ entry: RemoteEntry) {
        Task { await downloadEntry(entry) }
    }

    private func downloadEntry(_ entry: RemoteEntry) async {
        guard let backend else { return }
        let remotePath = remoteJoin(currentPath, entry.name)

        if entry.isDirectory {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = loc("Download here", "Скачать сюда", "Hierher laden", "Descargar aquí")
            panel.message = loc("Choose a folder for “\(entry.name)”", "Выберите папку для «\(entry.name)»", "Ordner für „\(entry.name)“ wählen", "Elige una carpeta para «\(entry.name)»")
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            let dest = dir.appendingPathComponent(entry.name)
            isBusy = true
            do {
                try await downloadDirectory(remotePath, to: dest)
                status = loc("Downloaded: \(entry.name)", "Скачано: \(entry.name)", "Geladen: \(entry.name)", "Descargado: \(entry.name)")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                status = loc("Download error: \(humanReadable(error))", "Ошибка скачивания: \(humanReadable(error))", "Download-Fehler: \(humanReadable(error))", "Error de descarga: \(humanReadable(error))")
            }
            isBusy = false
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.name
            panel.canCreateDirectories = true
            panel.prompt = loc("Download", "Скачать", "Laden", "Descargar")
            guard panel.runModal() == .OK, let dest = panel.url else { return }
            isBusy = true
            do {
                let data = try await backend.readFile(remotePath)
                try data.write(to: dest)
                status = loc("Downloaded: \(entry.name)", "Скачано: \(entry.name)", "Geladen: \(entry.name)", "Descargado: \(entry.name)")
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                status = loc("Download error: \(humanReadable(error))", "Ошибка скачивания: \(humanReadable(error))", "Download-Fehler: \(humanReadable(error))", "Error de descarga: \(humanReadable(error))")
            }
            isBusy = false
        }
    }

    private func downloadDirectory(_ remote: String, to localDir: URL) async throws {
        guard let backend else { return }
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        for child in try await children(of: remote) {
            let childRemote = remoteJoin(remote, child.name)
            let childLocal = localDir.appendingPathComponent(child.name)
            if child.isDir {
                try await downloadDirectory(childRemote, to: childLocal)
            } else {
                let data = try await backend.readFile(childRemote)
                try data.write(to: childLocal)
            }
        }
    }

    // MARK: - Upload (drag & drop from Finder)

    func upload(localFiles urls: [URL]) {
        guard uploadTask == nil else { return }   // one upload at a time
        uploadTask = Task { await uploadAll(urls) }
    }

    func cancelUpload() {
        uploadTask?.cancel()
    }

    private func uploadAll(_ urls: [URL]) async {
        guard backend != nil, !urls.isEmpty else { return }
        let targetDir = currentPath
        uploadFilesTotal = countFiles(urls)
        uploadFilesDone = 0
        uploadTotalBytes = totalBytes(urls)
        uploadDoneBytes = 0
        uploadCurrentName = ""
        uploadInProgress = true
        isBusy = true
        do {
            for url in urls {
                try await uploadItem(url, toDir: targetDir)
            }
            status = loc("Uploaded \(uploadFilesDone) file(s)", "Загружено файлов: \(uploadFilesDone)", "Hochgeladen: \(uploadFilesDone)", "Subidos: \(uploadFilesDone)")
            await refresh()
        } catch is CancellationError {
            status = loc("Upload cancelled (\(uploadFilesDone)/\(uploadFilesTotal))", "Загрузка отменена (\(uploadFilesDone)/\(uploadFilesTotal))", "Upload abgebrochen (\(uploadFilesDone)/\(uploadFilesTotal))", "Subida cancelada (\(uploadFilesDone)/\(uploadFilesTotal))")
            await refresh()
        } catch {
            status = loc("Upload error: \(humanReadable(error))", "Ошибка загрузки: \(humanReadable(error))", "Upload-Fehler: \(humanReadable(error))", "Error de subida: \(humanReadable(error))")
        }
        uploadInProgress = false
        isBusy = false
        uploadTask = nil
    }

    private func uploadItem(_ localURL: URL, toDir remoteDir: String) async throws {
        guard let backend else { return }
        try Task.checkCancellation()
        let remotePath = remoteJoin(remoteDir, localURL.lastPathComponent)

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)

        if isDir.boolValue {
            try? await backend.makeDirectory(remotePath)
            let children = try FileManager.default.contentsOfDirectory(
                at: localURL, includingPropertiesForKeys: nil)
            for child in children {
                try await uploadItem(child, toDir: remotePath)
            }
            return
        }

        let name = localURL.lastPathComponent
        uploadCurrentName = name
        status = loc("Uploading \(name)…", "Загрузка \(name)…", "Lade \(name)…", "Subiendo \(name)…")

        // Read off the main actor so the UI stays responsive.
        let data = try await Task.detached(priority: .utility) {
            try Data(contentsOf: localURL)
        }.value
        try Task.checkCancellation()

        do {
            try await backend.writeFile(remotePath, data: data) { [weak self] delta in
                self?.uploadDoneBytes += Int64(delta)
            }
        } catch {
            // Interrupted (cancel or error): drop the partially written file.
            try? await backend.removeFile(remotePath)
            throw error
        }
        uploadFilesDone += 1
    }

    /// Push a tracked file back to the server.
    func sync(_ file: OpenFile) async {
        guard let backend else { return }
        guard let index = openFiles.firstIndex(where: { $0.id == file.id }) else { return }
        openFiles[index].state = .uploading
        do {
            let data = try Data(contentsOf: file.localURL)
            try await backend.writeFile(file.remotePath, data: data, onProgress: { _ in })

            if let i = openFiles.firstIndex(where: { $0.id == file.id }) {
                openFiles[i].state = .synced
                openFiles[i].lastSyncedAt = Date()
                openFiles[i].lastModified = modificationDate(of: file.localURL) ?? openFiles[i].lastModified
            }
            status = loc("Saved to server: \(file.name)", "Сохранено на сервер: \(file.name)", "Auf Server gespeichert: \(file.name)", "Guardado en el servidor: \(file.name)")

            if remoteParent(file.remotePath) == currentPath {
                await refresh()
            }
        } catch {
            if let i = openFiles.firstIndex(where: { $0.id == file.id }) {
                openFiles[i].state = .error(humanReadable(error))
            }
            status = loc("Upload error \(file.name): \(humanReadable(error))", "Ошибка загрузки \(file.name): \(humanReadable(error))", "Upload-Fehler \(file.name): \(humanReadable(error))", "Error de subida \(file.name): \(humanReadable(error))")
        }
    }

    func reveal(_ file: OpenFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.localURL])
    }

    func reopen(_ file: OpenFile) {
        NSWorkspace.shared.open(file.localURL)
    }

    func stopTracking(_ file: OpenFile) {
        openFiles.removeAll { $0.id == file.id }
        if openFiles.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    // MARK: - Upload size helpers

    private func countFiles(_ urls: [URL]) -> Int {
        var total = 0
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil)) ?? []
                total += countFiles(children)
            } else {
                total += 1
            }
        }
        return total
    }

    private func totalBytes(_ urls: [URL]) -> Int64 {
        var sum: Int64 = 0
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                sum += totalBytes(children)
            } else {
                sum += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return sum
    }

    // MARK: - Save polling

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForSaves() }
        }
    }

    private func checkForSaves() async {
        let snapshot = openFiles.map { ($0.id, $0.localURL, $0.lastModified) }
        for (id, url, last) in snapshot {
            guard let mtime = modificationDate(of: url), mtime > last else { continue }
            guard let i = openFiles.firstIndex(where: { $0.id == id }) else { continue }
            openFiles[i].lastModified = mtime
            await sync(openFiles[i])
        }
    }

    private func modificationDate(of url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func humanReadable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
