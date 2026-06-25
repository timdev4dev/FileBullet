import Foundation
import Security

/// A previously used SFTP connection. Non-secret metadata only — the password
/// is kept separately in the macOS Keychain, keyed by `account`.
struct RecentConnection: Codable, Identifiable, Equatable {
    let host: String
    let port: Int
    let username: String
    /// Path to an OpenSSH private key, if this connection uses key auth.
    var keyPath: String?
    var proto: TransferProtocol

    var id: String { "\(proto.rawValue)://\(account)" }
    var account: String { "\(username)@\(host):\(port)" }
    var label: String { account }
    var usesKey: Bool { proto == .sftp && !(keyPath ?? "").isEmpty }

    init(host: String, port: Int, username: String, keyPath: String?, proto: TransferProtocol) {
        self.host = host
        self.port = port
        self.username = username
        self.keyPath = keyPath
        self.proto = proto
    }

    // Tolerate older saved entries that predate the `proto` field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(Int.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath)
        proto = try c.decodeIfPresent(TransferProtocol.self, forKey: .proto) ?? .sftp
    }
}

/// Persists the list of recent connections (UserDefaults) and their passwords
/// (Keychain). Newest first, de-duplicated by user@host:port.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var recents: [RecentConnection] = []

    private let defaultsKey = "recentConnections"
    private let maxCount = 12

    init() { load() }

    func remember(proto: TransferProtocol, host: String, port: Int, username: String, password: String, keyPath: String?) {
        let conn = RecentConnection(host: host, port: port, username: username, keyPath: keyPath, proto: proto)
        recents.removeAll { $0.id == conn.id }
        recents.insert(conn, at: 0)
        if recents.count > maxCount {
            recents = Array(recents.prefix(maxCount))
        }
        if !conn.usesKey {
            Keychain.set(password, account: conn.id)
        }
        save()
    }

    func password(for conn: RecentConnection) -> String? {
        Keychain.get(account: conn.id)
    }

    func remove(_ conn: RecentConnection) {
        recents.removeAll { $0.id == conn.id }
        Keychain.delete(account: conn.id)
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([RecentConnection].self, from: data)
        else { return }
        recents = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Minimal generic-password Keychain wrapper.
enum Keychain {
    private static let service = "local.sftpclient"

    static func set(_ password: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
