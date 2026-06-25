import SwiftUI

/// Top-level model: one tab per server connection.
@MainActor
final class AppModel: ObservableObject {
    @Published var sessions: [SFTPManager] = []
    @Published var selectedID: SFTPManager.ID?
    let store = ConnectionStore()
    let favorites = FavoritesStore()

    init() {
        addSession()
    }

    var selected: SFTPManager? {
        sessions.first { $0.id == selectedID }
    }

    func addSession() {
        let session = SFTPManager()
        sessions.append(session)
        selectedID = session.id
    }

    func close(_ session: SFTPManager) {
        Task { await session.disconnect() }
        let wasSelected = session.id == selectedID
        let index = sessions.firstIndex { $0.id == session.id }
        sessions.removeAll { $0.id == session.id }

        if sessions.isEmpty {
            addSession()
        } else if wasSelected {
            let next = min(index ?? 0, sessions.count - 1)
            selectedID = sessions[next].id
        }
    }
}
