import SwiftUI

/// Sheet for editing POSIX permissions (chmod) and owner/group (chown).
struct PermissionsEditor: View {
    let entry: RemoteEntry
    let apply: (UInt32, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: UInt32
    @State private var owner: String
    @State private var group: String

    init(entry: RemoteEntry, apply: @escaping (UInt32, String, String) -> Void) {
        self.entry = entry
        self.apply = apply
        let initial = entry.permissions ?? (entry.isDirectory ? 0o755 : 0o644)
        _mode = State(initialValue: initial)
        _owner = State(initialValue: entry.owner ?? "")
        _group = State(initialValue: entry.group ?? "")
    }

    private func bit(_ mask: UInt32) -> Binding<Bool> {
        Binding(
            get: { mode & mask != 0 },
            set: { mode = $0 ? (mode | mask) : (mode & ~mask) }
        )
    }

    private var octal: String { String(mode & 0o7777, radix: 8) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("Permissions", "Права доступа", "Rechte", "Permisos")).font(.headline)
                Text(entry.name).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Grid(horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    Text("").gridColumnAlignment(.leading)
                    Text(loc("Read", "Чтение", "Lesen", "Leer")).font(.caption).foregroundStyle(.secondary)
                    Text(loc("Write", "Запись", "Schreiben", "Escribir")).font(.caption).foregroundStyle(.secondary)
                    Text(loc("Exec", "Выполн.", "Ausf.", "Ejec.")).font(.caption).foregroundStyle(.secondary)
                }
                permRow(loc("Owner", "Владелец", "Eigentümer", "Propietario"), 0o400, 0o200, 0o100)
                permRow(loc("Group", "Группа", "Gruppe", "Grupo"), 0o040, 0o020, 0o010)
                permRow(loc("Others", "Остальные", "Andere", "Otros"), 0o004, 0o002, 0o001)
            }

            HStack(spacing: 8) {
                Text(loc("Octal:", "Восьмерично:", "Oktal:", "Octal:"))
                TextField("644", text: Binding(
                    get: { octal },
                    set: { text in
                        if let v = UInt32(text, radix: 8) { mode = v & 0o7777 }
                    }
                ))
                .frame(width: 70)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                Text(symbolic).font(.body.monospaced()).foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(loc("Owner", "Владелец", "Eigentümer", "Propietario"))
                    TextField(loc("user", "пользователь", "Benutzer", "usuario"), text: $owner)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(loc("Group", "Группа", "Gruppe", "Grupo"))
                    TextField(loc("group", "группа", "Gruppe", "grupo"), text: $group)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Text(loc("Changing the owner runs chown and needs privileges (usually root).", "Смена владельца выполняет chown и требует прав (обычно root).", "Eigentümerwechsel führt chown aus und braucht Rechte (meist root).", "Cambiar propietario ejecuta chown y requiere privilegios (normalmente root)."))
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(loc("Cancel", "Отмена", "Abbrechen", "Cancelar"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(loc("Apply", "Применить", "Anwenden", "Aplicar")) {
                    apply(mode, owner, group)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func permRow(_ title: String, _ r: UInt32, _ w: UInt32, _ x: UInt32) -> some View {
        GridRow {
            Text(title)
            Toggle("", isOn: bit(r)).labelsHidden()
            Toggle("", isOn: bit(w)).labelsHidden()
            Toggle("", isOn: bit(x)).labelsHidden()
        }
    }

    /// rwxr-xr-x style string.
    private var symbolic: String {
        let masks: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
        let chars = ["r", "w", "x", "r", "w", "x", "r", "w", "x"]
        return zip(masks, chars).map { mode & $0.0 != 0 ? $0.1 : "-" }.joined()
    }
}
