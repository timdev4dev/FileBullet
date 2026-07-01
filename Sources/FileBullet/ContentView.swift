import SwiftUI

struct ContentView: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabBar(app: app)
            Divider()
            if let session = app.selected {
                SessionView(manager: session, store: app.store, favorites: app.favorites)
                    .id(session.id)
            }
        }
    }
}

/// One tab's content: connection form or file browser, plus the status bar.
struct SessionView: View {
    @ObservedObject var manager: SFTPManager
    @ObservedObject var store: ConnectionStore
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        VStack(spacing: 0) {
            if manager.isConnected {
                BrowserView(manager: manager, favorites: favorites)
            } else {
                ConnectView(manager: manager, store: store, favorites: favorites)
            }
            StatusBar(manager: manager)
        }
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @ObservedObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(app.sessions) { session in
                        TabChip(
                            session: session,
                            isSelected: session.id == app.selectedID,
                            onSelect: { app.selectedID = session.id },
                            onClose: { app.close(session) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }

            Button { app.addSession() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .help(loc("New connection", "Новое подключение", "Neue Verbindung", "Nueva conexión"))
        }
        .frame(height: 38)
        .background(.bar)
    }
}

struct TabChip: View {
    @ObservedObject var session: SFTPManager
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.isConnected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(session.tabTitle)
                .font(.callout)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .opacity(hovering || isSelected ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 200)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Connection form

struct ConnectView: View {
    @ObservedObject var manager: SFTPManager
    @ObservedObject var store: ConnectionStore
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            form
            if !store.recents.isEmpty || !favorites.items.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    if !store.recents.isEmpty {
                        recentsList
                    }
                    if !favorites.items.isEmpty {
                        if !store.recents.isEmpty { Divider() }
                        favoritesList
                    }
                }
                .frame(width: 270)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var favoritesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("Favorites", "Избранное", "Favoriten", "Favoritos"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 8)
            List {
                ForEach(favorites.items) { fav in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fav.name).bold().lineLimit(1)
                            Text("\(fav.host) · \(fav.path)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button { favorites.remove(fav) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 1)
                    .contentShape(Rectangle())
                    .onTapGesture { useFavorite(fav) }
                }
            }
            .listStyle(.inset)
        }
    }

    /// Connect using saved credentials for the favorite's host, then jump to it.
    private func useFavorite(_ fav: Favorite) {
        guard let conn = store.recents.first(where: { $0.host == fav.host }) else {
            // No saved credentials for this host — prefill what we can.
            manager.draftHost = fav.host
            return
        }
        manager.draftProto = conn.proto
        manager.draftHost = conn.host
        manager.draftPort = String(conn.port)
        manager.draftUser = conn.username
        manager.draftKeyPath = conn.keyPath ?? ""
        manager.draftPassword = conn.usesKey ? "" : (store.password(for: conn) ?? "")
        let key = (conn.proto == .sftp && conn.usesKey) ? conn.keyPath : nil
        let password = conn.usesKey ? "" : (store.password(for: conn) ?? "")
        Task {
            await manager.connect(proto: conn.proto, host: conn.host, port: conn.port,
                                  username: conn.username, password: password, keyPath: key)
            if manager.isConnected {
                await manager.list(path: fav.path)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("New connection", "Подключение", "Verbindung", "Conexión"))
                .font(.title2).bold()

            Picker("", selection: $manager.draftProto) {
                Text("SFTP").tag(TransferProtocol.sftp)
                Text("FTP").tag(TransferProtocol.ftp)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)
            .onChange(of: manager.draftProto) { _, newValue in
                if manager.draftPort == "22" || manager.draftPort == "21" {
                    manager.draftPort = String(newValue.defaultPort)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(loc("Host", "Хост", "Host", "Host"))
                    TextField(loc("example.com or 192.168.0.1", "example.com или 192.168.0.1", "example.com oder 192.168.0.1", "example.com o 192.168.0.1"), text: $manager.draftHost)
                }
                GridRow {
                    Text(loc("Port", "Порт", "Port", "Puerto"))
                    TextField("22", text: $manager.draftPort)
                        .frame(width: 80)
                }
                GridRow {
                    Text(loc("User", "Пользователь", "Benutzer", "Usuario"))
                    TextField("root", text: $manager.draftUser)
                }
                GridRow {
                    Text(loc("Password", "Пароль", "Passwort", "Contraseña"))
                    SecureField("••••••••", text: $manager.draftPassword)
                        .disabled(!manager.draftKeyPath.isEmpty)
                }
                if manager.draftProto == .sftp {
                    GridRow {
                        Text(loc("SSH key", "SSH-ключ", "SSH-Schlüssel", "Clave SSH"))
                        HStack(spacing: 6) {
                            Button(keyButtonTitle) { chooseKey() }
                            if !manager.draftKeyPath.isEmpty {
                                Button {
                                    manager.draftKeyPath = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(loc("Remove key", "Убрать ключ", "Schlüssel entfernen", "Quitar clave"))
                            }
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            if manager.draftProto == .sftp, !manager.draftKeyPath.isEmpty {
                Text(loc("Key login — password is ignored.", "Вход по ключу — пароль игнорируется.", "Schlüssel-Login — Passwort wird ignoriert.", "Acceso por clave — se ignora la contraseña."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(loc("Connect", "Подключиться", "Verbinden", "Conectar")) { connect() }
                    .keyboardShortcut(.return)
                    .disabled(manager.isBusy)

                if manager.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("Recent", "Недавние", "Zuletzt", "Recientes"))
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 8)
            List {
                ForEach(store.recents) { conn in
                    HStack(spacing: 8) {
                        Image(systemName: conn.usesKey ? "key.fill" : "server.rack")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(conn.username).bold()
                            Text("\(conn.proto.label) · \(conn.host):\(conn.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            store.remove(conn)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(loc("Delete", "Удалить", "Löschen", "Eliminar"))
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { use(conn) }
                }
            }
            .listStyle(.inset)
        }
    }

    private var keyButtonTitle: String {
        manager.draftKeyPath.isEmpty
            ? loc("Choose file…", "Выбрать файл…", "Datei wählen…", "Elegir archivo…")
            : (manager.draftKeyPath as NSString).lastPathComponent
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = loc("Choose a private SSH key", "Выберите приватный SSH-ключ", "Privaten SSH-Schlüssel wählen", "Elige una clave SSH privada")
        panel.prompt = loc("Choose", "Выбрать", "Wählen", "Elegir")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            manager.draftKeyPath = url.path
        }
    }

    private func connect() {
        let proto = manager.draftProto
        let h = manager.draftHost.trimmingCharacters(in: .whitespaces)
        let u = manager.draftUser.trimmingCharacters(in: .whitespaces)
        let p = Int(manager.draftPort) ?? proto.defaultPort
        let pw = manager.draftPassword
        let key = (proto == .sftp && !manager.draftKeyPath.isEmpty) ? manager.draftKeyPath : nil
        Task {
            await manager.connect(proto: proto, host: h, port: p, username: u, password: pw, keyPath: key)
            if manager.isConnected {
                store.remember(proto: proto, host: h, port: p, username: u, password: pw, keyPath: key)
            }
        }
    }

    /// Fill the form from a saved connection and immediately connect.
    private func use(_ conn: RecentConnection) {
        manager.draftProto = conn.proto
        manager.draftHost = conn.host
        manager.draftPort = String(conn.port)
        manager.draftUser = conn.username
        manager.draftKeyPath = conn.keyPath ?? ""
        manager.draftPassword = conn.usesKey ? "" : (store.password(for: conn) ?? "")
        connect()
    }
}

// MARK: - File browser

struct BrowserView: View {
    @ObservedObject var manager: SFTPManager
    @ObservedObject var favorites: FavoritesStore
    @State private var deleteTargets: [RemoteEntry] = []
    @State private var permTarget: RemoteEntry?
    @State private var isDropTarget = false
    @State private var search = ""
    @State private var newItemKind: NewItemKind?
    @State private var newItemName = ""

    enum NewItemKind { case folder, file }

    private var filteredEntries: [RemoteEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return manager.entries }
        return manager.entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var browserSplit: some View {
        HSplitView {
            fileList
            Sidebar(manager: manager, favorites: favorites)
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 360)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if manager.terminalVisible && manager.shellSupported {
                VSplitView {
                    browserSplit
                    TerminalPanel(manager: manager)
                        .frame(minHeight: 120, idealHeight: 200)
                }
            } else {
                browserSplit
            }
        }
        .onChange(of: manager.currentPath) { _, _ in search = "" }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(
                get: { !deleteTargets.isEmpty },
                set: { if !$0 { deleteTargets = [] } }
            )
        ) {
            Button(loc("Delete", "Удалить", "Löschen", "Eliminar"), role: .destructive) {
                let targets = deleteTargets
                Task { await manager.deleteMany(targets) }
            }
            Button(loc("Cancel", "Отмена", "Abbrechen", "Cancelar"), role: .cancel) {}
        } message: {
            Text(loc("This cannot be undone.", "Действие необратимо.", "Dies kann nicht rückgängig gemacht werden.", "Esto no se puede deshacer."))
        }
        .sheet(item: $permTarget) { entry in
            PermissionsEditor(entry: entry) { mode, owner, group in
                Task { await manager.applyAttributes(entry, mode: mode, owner: owner, group: group) }
            }
        }
        .alert(
            newItemKind == .folder
                ? loc("New Folder", "Новая папка", "Neuer Ordner", "Nueva carpeta")
                : loc("New File", "Новый файл", "Neue Datei", "Nuevo archivo"),
            isPresented: Binding(
                get: { newItemKind != nil },
                set: { if !$0 { newItemKind = nil } }
            )
        ) {
            TextField(loc("Name", "Имя", "Name", "Nombre"), text: $newItemName)
            Button(loc("Cancel", "Отмена", "Abbrechen", "Cancelar"), role: .cancel) { newItemKind = nil }
            Button(loc("Create", "Создать", "Erstellen", "Crear")) {
                let name = newItemName
                let kind = newItemKind
                Task {
                    if kind == .folder { await manager.createFolder(name) }
                    else { await manager.createFile(name) }
                }
                newItemKind = nil
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                manager.goUp()
            } label: {
                Image(systemName: "arrow.up")
            }
            .help(loc("Go up", "На уровень вверх", "Eine Ebene höher", "Subir un nivel"))
            .disabled(manager.currentPath == "/")

            Button {
                Task { await manager.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(loc("Refresh", "Обновить", "Aktualisieren", "Actualizar"))

            Button {
                openSelected()
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .help(loc("Open selected (Enter)", "Открыть выбранное (Enter)", "Auswahl öffnen (Enter)", "Abrir selección (Enter)"))
            .keyboardShortcut(.return, modifiers: [])
            .disabled(manager.selectedEntryIDs.count != 1)

            Button {
                favorites.toggle(host: manager.connectedHost, path: manager.currentPath)
            } label: {
                Image(systemName: favorites.contains(host: manager.connectedHost, path: manager.currentPath)
                      ? "star.fill" : "star")
            }
            .help(loc("Add current folder to favorites", "Добавить текущую папку в избранное", "Aktuellen Ordner zu Favoriten", "Añadir carpeta a favoritos"))

            Button {
                deleteTargets = selectedEntries
            } label: {
                Image(systemName: "trash")
            }
            .help(loc("Delete selection (⌘⌫)", "Удалить выделенное (⌘⌫)", "Auswahl löschen (⌘⌫)", "Eliminar selección (⌘⌫)"))
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(manager.selectedEntryIDs.isEmpty)

            Button {
                manager.copyToClipboard(selectedEntries)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help(loc("Copy (⌘C)", "Копировать (⌘C)", "Kopieren (⌘C)", "Copiar (⌘C)"))
            .keyboardShortcut("c", modifiers: .command)
            .disabled(manager.selectedEntryIDs.isEmpty)

            Button {
                manager.paste()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help(loc("Paste (⌘V)", "Вставить (⌘V)", "Einfügen (⌘V)", "Pegar (⌘V)"))
            .keyboardShortcut("v", modifiers: .command)
            .disabled(manager.clipboard.isEmpty)

            Button {
                manager.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help(loc("Undo last create/paste (⌘Z)", "Отменить последнее создание/вставку (⌘Z)", "Letztes rückgängig (⌘Z)", "Deshacer último (⌘Z)"))
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!manager.canUndo)

            TextField(loc("Path", "Путь", "Pfad", "Ruta"), text: Binding(
                get: { manager.currentPath },
                set: { _ in }
            ))
            .textFieldStyle(.roundedBorder)
            .disabled(true)

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                TextField(loc("Filter", "Фильтр", "Filter", "Filtrar"), text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))

            if manager.isBusy {
                ProgressView().controlSize(.small)
            }

            Button {
                manager.terminalVisible.toggle()
            } label: {
                Image(systemName: "terminal")
                    .foregroundStyle(manager.terminalVisible ? Color.accentColor : Color.primary)
            }
            .help(loc("Terminal", "Терминал", "Terminal", "Terminal"))
            .disabled(!manager.shellSupported)

            Button(loc("Disconnect", "Отключиться", "Trennen", "Desconectar")) {
                Task { await manager.disconnect() }
            }
        }
        .padding(8)
    }

    private var deleteDialogTitle: String {
        if deleteTargets.count == 1 {
            let n = deleteTargets[0].name
            return loc("Delete “\(n)”?", "Удалить «\(n)»?", "„\(n)“ löschen?", "¿Eliminar «\(n)»?")
        }
        let c = deleteTargets.count
        return loc("Delete \(c) items?", "Удалить объектов: \(c)?", "\(c) Objekte löschen?", "¿Eliminar \(c) elementos?")
    }

    private var selectedEntries: [RemoteEntry] {
        manager.entries.filter { manager.selectedEntryIDs.contains($0.id) }
    }

    private func openSelected() {
        guard manager.selectedEntryIDs.count == 1, let id = manager.selectedEntryIDs.first,
              let entry = manager.entries.first(where: { $0.id == id }) else { return }
        manager.open(entry)
    }

    private var openBadges: [String: SyncState] {
        var map: [String: SyncState] = [:]
        for file in manager.openFiles where remoteParent(file.remotePath) == manager.currentPath {
            // Skip files that were just opened but never uploaded yet — no badge.
            if case .synced = file.state, file.lastSyncedAt == nil { continue }
            map[(file.remotePath as NSString).lastPathComponent] = file.state
        }
        return map
    }

    private var fileList: some View {
        FileTableView(
            entries: filteredEntries,
            badges: openBadges,
            selection: $manager.selectedEntryIDs,
            onOpen: { manager.open($0) },
            onOpenWith: { manager.open($0, withApp: $1) },
            onDownload: { manager.downloadMany($0) },
            onCopyPath: { entries in
                let paths = entries.map { remoteJoin(manager.currentPath, $0.name) }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
                manager.status = loc("Copied \(paths.count) path(s)", "Скопировано путей: \(paths.count)", "Pfade kopiert: \(paths.count)", "Rutas copiadas: \(paths.count)")
            },
            onDuplicate: { entry in Task { await manager.duplicate(entry) } },
            onRename: { entry, newName in Task { await manager.rename(entry, to: newName) } },
            onPermissions: { permTarget = $0 },
            onDelete: { deleteTargets = $0 },
            onFavorite: { entry in
                favorites.add(host: manager.connectedHost,
                              path: remoteJoin(manager.currentPath, entry.name))
            },
            onCopy: { manager.copyToClipboard($0) },
            onPaste: { manager.paste() },
            canPaste: !manager.clipboard.isEmpty,
            onNewFolder: { newItemName = ""; newItemKind = .folder },
            onNewFile: { newItemName = ""; newItemKind = .file },
            onRefresh: { Task { await manager.refresh() } }
        )
        .frame(minWidth: 360)
        .overlay {
            if filteredEntries.isEmpty && !manager.isBusy {
                Text(manager.entries.isEmpty
                     ? loc("Empty folder", "Пустая папка", "Leerer Ordner", "Carpeta vacía")
                     : loc("No matches", "Ничего не найдено", "Keine Treffer", "Sin coincidencias"))
                    .foregroundStyle(.secondary)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            manager.upload(localFiles: urls)
            return true
        } isTargeted: { isDropTarget = $0 }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label(
                            loc("Drop to upload here", "Отпустите для загрузки сюда", "Zum Hochladen hier ablegen", "Suelta para subir aquí"),
                            systemImage: "arrow.down.doc.fill"
                        )
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Right sidebar (favorites + editing files)

struct Sidebar: View {
    @ObservedObject var manager: SFTPManager
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        VStack(spacing: 0) {
            FavoritesPanel(manager: manager, favorites: favorites)
            if !manager.openFiles.isEmpty {
                Divider()
                OpenFilesPanel(manager: manager)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct FavoritesPanel: View {
    @ObservedObject var manager: SFTPManager
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        let items = favorites.list(host: manager.connectedHost)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc("Favorites", "Избранное", "Favoriten", "Favoritos"))
                    .font(.headline)
                Spacer()
                Button {
                    favorites.add(host: manager.connectedHost, path: manager.currentPath)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help(loc("Add current folder", "Добавить текущую папку", "Aktuellen Ordner hinzufügen", "Añadir carpeta actual"))
            }
            .padding(8)
            Divider()

            if items.isEmpty {
                Text(loc("No favorites yet", "Пока пусто", "Noch keine Favoriten", "Sin favoritos"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                List {
                    ForEach(items) { fav in
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fav.name).lineLimit(1)
                                Text(fav.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button {
                                favorites.remove(fav)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .opacity(0.8)
                        }
                        .padding(.vertical, 1)
                        .contentShape(Rectangle())
                        .onTapGesture { manager.go(to: fav.path) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - Open / editing files panel

struct OpenFilesPanel: View {
    @ObservedObject var manager: SFTPManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(loc("Editing files (\(manager.openFiles.count))", "Редактируемые файлы (\(manager.openFiles.count))", "Bearbeitete Dateien (\(manager.openFiles.count))", "Archivos en edición (\(manager.openFiles.count))"))
                .font(.headline)
                .padding(8)
            Divider()
            List(manager.openFiles) { file in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        stateIcon(file.state)
                        Text(file.name).bold()
                    }
                    Text(file.remotePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        statusIcon(file.state)
                        Text(statusText(file))
                            .font(.caption)
                            .foregroundStyle(statusColor(file.state))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: 10) {
                        Button(loc("Save", "Сохранить", "Speichern", "Guardar")) { Task { await manager.sync(file) } }
                        Button(loc("Open", "Открыть", "Öffnen", "Abrir")) { manager.reopen(file) }
                        Button(loc("Reveal", "В Finder", "Im Finder", "En Finder")) { manager.reveal(file) }
                        Button(role: .destructive) {
                            manager.stopTracking(file)
                        } label: { Image(systemName: "xmark.circle") }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: SyncState) -> some View {
        switch state {
        case .synced:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .uploading:
            ProgressView().controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: SyncState) -> some View {
        switch state {
        case .synced:
            Image(systemName: "checkmark.circle.fill").font(.caption)
        case .uploading:
            Image(systemName: "arrow.up.circle.fill").font(.caption)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption)
        }
    }

    private func statusText(_ file: OpenFile) -> String {
        switch file.state {
        case .uploading:
            return loc("Uploading to server…", "Загрузка на сервер…", "Wird hochgeladen…", "Subiendo al servidor…")
        case .error(let message):
            return loc("Error: \(message)", "Ошибка: \(message)", "Fehler: \(message)", "Error: \(message)")
        case .synced:
            if let at = file.lastSyncedAt {
                return loc("Saved • \(at.formatted(date: .omitted, time: .standard))", "Сохранено • \(at.formatted(date: .omitted, time: .standard))", "Gespeichert • \(at.formatted(date: .omitted, time: .standard))", "Guardado • \(at.formatted(date: .omitted, time: .standard))")
            }
            return loc("Opened, no changes", "Открыт, изменений нет", "Geöffnet, keine Änderungen", "Abierto, sin cambios")
        }
    }

    private func statusColor(_ state: SyncState) -> Color {
        switch state {
        case .synced: return .green
        case .uploading: return .blue
        case .error: return .orange
        }
    }
}

// MARK: - SSH command console

struct TerminalPanel: View {
    @ObservedObject var manager: SFTPManager
    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(loc("Terminal", "Терминал", "Terminal", "Terminal")).font(.headline)
                if manager.terminalBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button { manager.clearTerminal() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(loc("Clear", "Очистить", "Leeren", "Limpiar"))
                Button { manager.terminalVisible = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(loc("Close", "Закрыть", "Schließen", "Cerrar"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(manager.terminalLog)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: manager.terminalLog) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }

            Divider()
            HStack(spacing: 6) {
                Text("$").foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))
                TextField(loc("Type a command…", "Введите команду…", "Befehl eingeben…", "Escribe un comando…"), text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($inputFocused)
                    .onSubmit(run)
                    .disabled(manager.terminalBusy)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { inputFocused = true }
    }

    private func run() {
        let command = input
        input = ""
        Task { await manager.runShell(command) }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var manager: SFTPManager

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        Divider()
        HStack(spacing: 10) {
            Text(manager.status.isEmpty ? loc("Ready", "Готово", "Bereit", "Listo") : manager.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if manager.uploadInProgress {
                ProgressView(value: Double(manager.uploadDoneBytes),
                             total: Double(max(manager.uploadTotalBytes, 1)))
                    .frame(width: 130)
                Text("\(byteString(manager.uploadDoneBytes)) / \(byteString(manager.uploadTotalBytes))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    manager.cancelUpload()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(loc("Cancel upload", "Отменить загрузку", "Upload abbrechen", "Cancelar subida"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
