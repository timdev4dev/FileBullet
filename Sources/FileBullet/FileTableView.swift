import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AppKit-backed file list. Native NSTableView gives instant single-click
/// selection and a real double-click action — none of the SwiftUI tap-gesture
/// disambiguation delay. Also hosts the right-click context menu.
/// Name-column cell that carries a small sync badge overlaid on the file icon.
final class NameCellView: NSTableCellView {
    let badge = NSImageView()
}

struct FileTableView: NSViewRepresentable {
    var entries: [RemoteEntry]
    /// filename → sync state, for files in this directory currently being edited.
    var badges: [String: SyncState]
    @Binding var selection: Set<RemoteEntry.ID>
    var onOpen: (RemoteEntry) -> Void
    var onOpenWith: (RemoteEntry, URL?) -> Void
    var onDownload: ([RemoteEntry]) -> Void
    var onCopyPath: ([RemoteEntry]) -> Void
    var onDuplicate: (RemoteEntry) -> Void
    var onRename: (RemoteEntry, String) -> Void
    var onPermissions: (RemoteEntry) -> Void
    var onDelete: ([RemoteEntry]) -> Void
    var onFavorite: (RemoteEntry) -> Void
    var onCopy: ([RemoteEntry]) -> Void
    var onPaste: () -> Void
    var canPaste: Bool
    var onNewFolder: () -> Void
    var onNewFile: () -> Void
    var onRefresh: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 2)

        let nameCol = NSTableColumn(identifier: .init("name"))
        nameCol.title = loc("Name", "Имя", "Name", "Nombre")
        nameCol.width = 240
        nameCol.minWidth = 120
        nameCol.resizingMask = .userResizingMask
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)
        table.addTableColumn(nameCol)

        let ownerCol = NSTableColumn(identifier: .init("owner"))
        ownerCol.title = loc("Owner", "Владелец", "Eigentümer", "Propietario")
        ownerCol.width = 100
        ownerCol.minWidth = 70
        ownerCol.resizingMask = .userResizingMask
        ownerCol.sortDescriptorPrototype = NSSortDescriptor(key: "owner", ascending: true)
        table.addTableColumn(ownerCol)

        let dateCol = NSTableColumn(identifier: .init("date"))
        dateCol.title = loc("Modified", "Изменён", "Geändert", "Modificado")
        dateCol.width = 150
        dateCol.minWidth = 110
        dateCol.resizingMask = .userResizingMask
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
        table.addTableColumn(dateCol)

        let sizeCol = NSTableColumn(identifier: .init("size"))
        sizeCol.title = loc("Size", "Размер", "Größe", "Tamaño")
        sizeCol.width = 90
        sizeCol.minWidth = 70
        sizeCol.resizingMask = .userResizingMask
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        table.addTableColumn(sizeCol)

        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.headerView = NSTableHeaderView()

        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        context.coordinator.table = table

        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }

        let incomingIDs = entries.map(\.id)
        let entriesChanged = context.coordinator.incomingIDs != incomingIDs
        let badgesChanged = context.coordinator.badges != badges
        if entriesChanged {
            context.coordinator.incomingIDs = incomingIDs
            context.coordinator.entries = context.coordinator.applySort(entries)
        }
        if badgesChanged {
            context.coordinator.badges = badges
        }
        if entriesChanged || badgesChanged {
            table.reloadData()
        }

        // Keep the table's selection in sync with the SwiftUI binding.
        let sorted = context.coordinator.entries
        var desired = IndexSet()
        for (i, entry) in sorted.enumerated() where selection.contains(entry.id) {
            desired.insert(i)
        }
        if desired != table.selectedRowIndexes {
            context.coordinator.isSyncingSelection = true
            table.selectRowIndexes(desired, byExtendingSelection: false)
            context.coordinator.isSyncingSelection = false
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        var parent: FileTableView
        var entries: [RemoteEntry]
        var incomingIDs: [UUID] = []
        var badges: [String: SyncState] = [:]
        private var sort: (key: String, ascending: Bool)?
        weak var table: NSTableView?
        private var contextEntry: RemoteEntry?
        private var contextRow: Int = -1
        private var contextTargets: [RemoteEntry] = []
        var isSyncingSelection = false

        init(_ parent: FileTableView) {
            self.parent = parent
            self.entries = parent.entries
        }

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        /// Reorder items by the active sort column (nil = server's default order).
        func applySort(_ items: [RemoteEntry]) -> [RemoteEntry] {
            guard let sort else { return items }
            let asc = sort.ascending
            func byName(_ a: RemoteEntry, _ b: RemoteEntry) -> Bool {
                a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return items.sorted { a, b in
                switch sort.key {
                case "date":
                    let da = a.modified ?? .distantPast, db = b.modified ?? .distantPast
                    if da == db { return byName(a, b) }
                    return asc ? da < db : da > db
                case "size":
                    let sa = a.size ?? 0, sb = b.size ?? 0
                    if sa == sb { return byName(a, b) }
                    return asc ? sa < sb : sa > sb
                case "owner":
                    let oa = a.owner ?? "", ob = b.owner ?? ""
                    if oa == ob { return byName(a, b) }
                    let r = oa.localizedCaseInsensitiveCompare(ob)
                    return asc ? r == .orderedAscending : r == .orderedDescending
                default:
                    return asc ? byName(a, b) : !byName(a, b)
                }
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
            sort = (key, descriptor.ascending)
            entries = applySort(entries)
            tableView.reloadData()
            var indexes = IndexSet()
            for (i, entry) in entries.enumerated() where parent.selection.contains(entry.id) {
                indexes.insert(i)
            }
            isSyncingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            isSyncingSelection = false
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < entries.count else { return nil }
            let entry = entries[row]
            let columnID = tableColumn?.identifier.rawValue ?? "name"
            let cellID = NSUserInterfaceItemIdentifier(columnID + "Cell")

            let cell = (tableView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView)
                ?? makeCell(id: cellID, kind: columnID)

            switch columnID {
            case "name":
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = icon(for: entry)
                cell.imageView?.contentTintColor = nil
                if let nameCell = cell as? NameCellView {
                    if let state = badges[entry.name] {
                        nameCell.badge.image = badgeImage(for: state)
                        nameCell.badge.toolTip = badgeTooltip(for: state)
                        nameCell.badge.isHidden = false
                    } else {
                        nameCell.badge.image = nil
                        nameCell.badge.isHidden = true
                    }
                }
            case "date":
                cell.textField?.stringValue = entry.displayDate
            case "owner":
                cell.textField?.stringValue = entry.displayOwner
            default:
                cell.textField?.stringValue = entry.displaySize
            }
            return cell
        }

        private func makeCell(id: NSUserInterfaceItemIdentifier, kind: String) -> NSTableCellView {
            let hasImage = kind == "name"
            let cell: NSTableCellView = hasImage ? NameCellView() : NSTableCellView()
            cell.identifier = id

            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            cell.textField = text
            cell.addSubview(text)

            if hasImage {
                // Name field: editable in place (Finder-style rename).
                text.isEditable = true
                text.isBordered = false
                text.focusRingType = .none
                text.drawsBackground = true
                text.backgroundColor = .clear
                text.delegate = self
            }

            if hasImage {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.imageView = image
                cell.addSubview(image)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])

                if let nameCell = cell as? NameCellView {
                    let badge = nameCell.badge
                    badge.translatesAutoresizingMaskIntoConstraints = false
                    badge.imageScaling = .scaleProportionallyUpOrDown
                    cell.addSubview(badge)
                    NSLayoutConstraint.activate([
                        badge.centerXAnchor.constraint(equalTo: image.trailingAnchor, constant: -1),
                        badge.centerYAnchor.constraint(equalTo: image.bottomAnchor, constant: -1),
                        badge.widthAnchor.constraint(equalToConstant: 13),
                        badge.heightAnchor.constraint(equalToConstant: 13),
                    ])
                }
            } else {
                text.alignment = kind == "size" ? .right : .left
                text.textColor = .secondaryLabelColor
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, !isSyncingSelection else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { index -> RemoteEntry.ID? in
                index < entries.count ? entries[index].id : nil
            })
            guard parent.selection != ids else { return }
            // Defer to avoid mutating SwiftUI state during a view update.
            DispatchQueue.main.async { [parent] in
                parent.selection = ids
            }
        }

        private var iconCache: [String: NSImage] = [:]

        /// System file-type icon (Finder-style), cached by kind/extension.
        private func icon(for entry: RemoteEntry) -> NSImage {
            let key: String
            if entry.isDirectory { key = ":dir" }
            else if entry.isSymlink { key = ":symlink" }
            else {
                let ext = (entry.name as NSString).pathExtension.lowercased()
                key = ext.isEmpty ? ":file" : ext
            }
            if let cached = iconCache[key] { return cached }

            let image: NSImage
            if entry.isDirectory {
                image = NSWorkspace.shared.icon(for: .folder)
            } else if entry.isSymlink {
                image = NSWorkspace.shared.icon(for: .aliasFile)
            } else {
                let ext = (entry.name as NSString).pathExtension
                let type = (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? .data
                image = NSWorkspace.shared.icon(for: type)
            }
            iconCache[key] = image
            return image
        }

        private func badgeImage(for state: SyncState) -> NSImage? {
            let symbol: String
            let tint: NSColor
            switch state {
            case .uploading: symbol = "arrow.up.circle.fill"; tint = .systemBlue
            case .synced:    symbol = "checkmark.circle.fill"; tint = .systemGreen
            case .error:     symbol = "exclamationmark.circle.fill"; tint = .systemOrange
            }
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, tint])
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }

        private func badgeTooltip(for state: SyncState) -> String {
            switch state {
            case .uploading: return loc("Uploading to server…", "Загружается на сервер…", "Wird hochgeladen…", "Subiendo al servidor…")
            case .synced:    return loc("Uploaded to server", "Загружен на сервер", "Auf Server hochgeladen", "Subido al servidor")
            case .error:     return loc("Upload error", "Ошибка загрузки", "Upload-Fehler", "Error de subida")
            }
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let table else { return }
            let row = table.clickedRow
            guard row >= 0, row < entries.count else { return }
            parent.onOpen(entries[row])
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0, table.clickedRow < entries.count else {
                contextEntry = nil
                contextRow = -1
                contextTargets = []
                if parent.canPaste {
                    addItem(menu, loc("Paste", "Вставить", "Einfügen", "Pegar"), #selector(ctxPaste))
                    menu.addItem(.separator())
                }
                addItem(menu, loc("New Folder…", "Создать папку…", "Neuer Ordner…", "Nueva carpeta…"), #selector(ctxNewFolder))
                addItem(menu, loc("New File…", "Создать файл…", "Neue Datei…", "Nuevo archivo…"), #selector(ctxNewFile))
                menu.addItem(.separator())
                addItem(menu, loc("Refresh", "Обновить", "Aktualisieren", "Actualizar"), #selector(ctxRefresh))
                return
            }
            let clicked = entries[table.clickedRow]
            contextEntry = clicked
            contextRow = table.clickedRow

            // If the clicked row is part of a multi-selection, act on the whole set.
            let sel = parent.selection
            let targets = (sel.contains(clicked.id) && sel.count > 1)
                ? entries.filter { sel.contains($0.id) }
                : [clicked]
            contextTargets = targets

            if targets.count > 1 {
                addItem(menu, loc("Copy", "Копировать", "Kopieren", "Copiar"), #selector(ctxCopy))
                if parent.canPaste {
                    addItem(menu, loc("Paste", "Вставить", "Einfügen", "Pegar"), #selector(ctxPaste))
                }
                menu.addItem(.separator())
                addItem(menu, loc("Download \(targets.count) items…", "Скачать (\(targets.count))…", "\(targets.count) herunterladen…", "Descargar (\(targets.count))…"), #selector(ctxDownload))
                addItem(menu, loc("Copy Paths", "Скопировать пути", "Pfade kopieren", "Copiar rutas"), #selector(ctxCopyPath))
                menu.addItem(.separator())
                addItem(menu, loc("Delete \(targets.count) items", "Удалить (\(targets.count))", "\(targets.count) löschen", "Eliminar (\(targets.count))"), #selector(ctxDelete))
                menu.addItem(.separator())
                addItem(menu, loc("Refresh", "Обновить", "Aktualisieren", "Actualizar"), #selector(ctxRefresh))
                return
            }

            let entry = clicked
            addItem(menu, loc("Open", "Открыть", "Öffnen", "Abrir"), #selector(ctxOpen))

            if entry.isDirectory {
                addItem(menu, loc("Add to Favorites", "В избранное", "Zu Favoriten", "A favoritos"), #selector(ctxFavorite))
                menu.addItem(.separator())
            }

            if !entry.isDirectory {
                let openWith = NSMenuItem(title: loc("Open With", "Открыть с помощью", "Öffnen mit", "Abrir con"), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for appURL in applicationURLs(for: entry) {
                    let item = NSMenuItem(title: appName(appURL),
                                          action: #selector(ctxOpenWithApp(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = appURL
                    item.image = appIcon(appURL)
                    submenu.addItem(item)
                }
                if !submenu.items.isEmpty { submenu.addItem(.separator()) }
                let other = NSMenuItem(title: loc("Other…", "Другое…", "Andere…", "Otra…"),
                                       action: #selector(ctxOpenWithOther),
                                       keyEquivalent: "")
                other.target = self
                submenu.addItem(other)
                openWith.submenu = submenu
                menu.addItem(openWith)
            }

            addItem(menu, loc("Download…", "Скачать…", "Herunterladen…", "Descargar…"), #selector(ctxDownload))
            addItem(menu, loc("Copy Path", "Скопировать путь", "Pfad kopieren", "Copiar ruta"), #selector(ctxCopyPath))
            menu.addItem(.separator())
            addItem(menu, loc("Copy", "Копировать", "Kopieren", "Copiar"), #selector(ctxCopy))
            if parent.canPaste {
                addItem(menu, loc("Paste", "Вставить", "Einfügen", "Pegar"), #selector(ctxPaste))
            }
            addItem(menu, loc("Duplicate", "Дублировать", "Duplizieren", "Duplicar"), #selector(ctxDuplicate))
            addItem(menu, loc("Rename…", "Переименовать…", "Umbenennen…", "Renombrar…"), #selector(ctxRename))
            addItem(menu, loc("Permissions…", "Права доступа…", "Rechte…", "Permisos…"), #selector(ctxPermissions))
            menu.addItem(.separator())
            addItem(menu, loc("Delete", "Удалить", "Löschen", "Eliminar"), #selector(ctxDelete))
            menu.addItem(.separator())
            addItem(menu, loc("New Folder…", "Создать папку…", "Neuer Ordner…", "Nueva carpeta…"), #selector(ctxNewFolder))
            addItem(menu, loc("New File…", "Создать файл…", "Neue Datei…", "Nuevo archivo…"), #selector(ctxNewFile))
            menu.addItem(.separator())
            addItem(menu, loc("Refresh", "Обновить", "Aktualisieren", "Actualizar"), #selector(ctxRefresh))
        }

        @discardableResult
        private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }

        private func applicationURLs(for entry: RemoteEntry) -> [URL] {
            let ext = (entry.name as NSString).pathExtension
            guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return [] }
            return NSWorkspace.shared.urlsForApplications(toOpen: type)
        }

        private func appName(_ url: URL) -> String {
            FileManager.default.displayName(atPath: url.path)
        }

        private func appIcon(_ url: URL) -> NSImage {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }

        @objc private func ctxOpen() {
            if let entry = contextEntry { parent.onOpen(entry) }
        }

        @objc private func ctxOpenWithApp(_ sender: NSMenuItem) {
            guard let entry = contextEntry, let appURL = sender.representedObject as? URL else { return }
            parent.onOpenWith(entry, appURL)
        }

        @objc private func ctxOpenWithOther() {
            guard let entry = contextEntry else { return }
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = false
            panel.prompt = loc("Choose", "Выбрать", "Wählen", "Elegir")
            if panel.runModal() == .OK, let appURL = panel.url {
                parent.onOpenWith(entry, appURL)
            }
        }

        @objc private func ctxDownload() {
            if !contextTargets.isEmpty { parent.onDownload(contextTargets) }
        }

        @objc private func ctxCopyPath() {
            if !contextTargets.isEmpty { parent.onCopyPath(contextTargets) }
        }

        @objc private func ctxDuplicate() {
            if let entry = contextEntry { parent.onDuplicate(entry) }
        }

        @objc private func ctxRename() {
            beginRename(row: contextRow)
        }

        /// Start in-place editing of the name field for a row.
        func beginRename(row: Int) {
            guard let table, row >= 0, row < entries.count else { return }
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.editColumn(0, row: row, with: nil, select: true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let table else { return }
            let row = table.row(for: field)
            guard row >= 0, row < entries.count else { return }
            let entry = entries[row]
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if newName.isEmpty || newName == entry.name {
                field.stringValue = entry.name  // revert
            } else {
                parent.onRename(entry, newName)
            }
        }

        @objc private func ctxPermissions() {
            if let entry = contextEntry { parent.onPermissions(entry) }
        }

        @objc private func ctxDelete() {
            if !contextTargets.isEmpty { parent.onDelete(contextTargets) }
        }

        @objc private func ctxRefresh() {
            parent.onRefresh()
        }

        @objc private func ctxCopy() {
            if !contextTargets.isEmpty { parent.onCopy(contextTargets) }
        }

        @objc private func ctxPaste() {
            parent.onPaste()
        }

        @objc private func ctxNewFolder() {
            parent.onNewFolder()
        }

        @objc private func ctxNewFile() {
            parent.onNewFile()
        }

        @objc private func ctxFavorite() {
            if let entry = contextEntry { parent.onFavorite(entry) }
        }
    }
}
