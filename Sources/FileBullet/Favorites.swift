import Foundation

/// A bookmarked remote folder, scoped to a host.
struct Favorite: Codable, Identifiable, Equatable {
    var host: String
    var path: String

    var id: String { "\(host)|\(path)" }
    var name: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? path : last
    }
}

/// Persists favorite folders across sessions (shared by all tabs).
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var items: [Favorite] = []

    private let defaultsKey = "favorites"

    init() { load() }

    func list(host: String) -> [Favorite] {
        items.filter { $0.host == host }
    }

    func contains(host: String, path: String) -> Bool {
        items.contains { $0.host == host && $0.path == path }
    }

    func add(host: String, path: String) {
        guard !host.isEmpty, !contains(host: host, path: path) else { return }
        items.append(Favorite(host: host, path: path))
        save()
    }

    func remove(_ favorite: Favorite) {
        items.removeAll { $0.id == favorite.id }
        save()
    }

    func toggle(host: String, path: String) {
        if let existing = items.first(where: { $0.host == host && $0.path == path }) {
            remove(existing)
        } else {
            add(host: host, path: path)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([Favorite].self, from: data)
        else { return }
        items = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
