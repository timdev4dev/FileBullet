import Foundation
import Citadel
import Crypto
import NIOCore

enum KeyAuthError: LocalizedError {
    case notOpenSSH
    case encrypted
    case rsaUnsupported
    case unsupported(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .notOpenSSH:
            return loc("Not an OpenSSH-format key. Convert it: ssh-keygen -p -f <key> (or create an ed25519 key).", "Не похоже на ключ в формате OpenSSH. Сконвертируйте: ssh-keygen -p -f <ключ> (или создайте ed25519).", "Kein Schlüssel im OpenSSH-Format. Konvertieren: ssh-keygen -p -f <key> (oder ed25519 erstellen).", "No es una clave en formato OpenSSH. Conviértela: ssh-keygen -p -f <clave> (o crea una ed25519).")
        case .encrypted:
            return loc("The key is passphrase-protected, which isn't supported yet. Remove it: ssh-keygen -p -f <key>.", "Ключ зашифрован паролем — это пока не поддерживается. Уберите пароль: ssh-keygen -p -f <ключ>.", "Der Schlüssel ist passwortgeschützt — noch nicht unterstützt. Entfernen: ssh-keygen -p -f <key>.", "La clave tiene contraseña, aún no compatible. Quítala: ssh-keygen -p -f <clave>.")
        case .rsaUnsupported:
            return loc("RSA keys aren't supported yet. Use ed25519 or ECDSA: ssh-keygen -t ed25519.", "RSA-ключи пока не поддерживаются. Используйте ed25519 или ECDSA: ssh-keygen -t ed25519.", "RSA-Schlüssel werden noch nicht unterstützt. Nutze ed25519 oder ECDSA: ssh-keygen -t ed25519.", "Las claves RSA aún no son compatibles. Usa ed25519 o ECDSA: ssh-keygen -t ed25519.")
        case .unsupported(let type):
            return loc("Unsupported key type: \(type).", "Неподдерживаемый тип ключа: \(type).", "Nicht unterstützter Schlüsseltyp: \(type).", "Tipo de clave no compatible: \(type).")
        case .malformed:
            return loc("Couldn't parse the private key.", "Не удалось разобрать приватный ключ.", "Privater Schlüssel konnte nicht gelesen werden.", "No se pudo analizar la clave privada.")
        }
    }
}

/// Parses an unencrypted OpenSSH private key file and builds an
/// SSHAuthenticationMethod. Supports ed25519 and ECDSA (P-256/384/521).
enum SSHKeyLoader {
    static func authentication(username: String, keyString: String) throws -> SSHAuthenticationMethod {
        let lines = keyString.split(whereSeparator: \.isNewline)
        guard let begin = lines.firstIndex(where: { $0.contains("BEGIN OPENSSH PRIVATE KEY") }),
              let end = lines.firstIndex(where: { $0.contains("END OPENSSH PRIVATE KEY") }),
              begin < end else {
            throw KeyAuthError.notOpenSSH
        }
        let base64 = lines[(begin + 1)..<end].joined()
        guard let data = Data(base64Encoded: base64) else { throw KeyAuthError.malformed }

        var buffer = ByteBuffer(bytes: data)

        // Header: "openssh-key-v1\0"
        guard let magic = buffer.readString(length: 15), magic == "openssh-key-v1\0" else {
            throw KeyAuthError.malformed
        }
        let cipher = try readString(&buffer)
        _ = try readBytes(&buffer)  // kdfname
        _ = try readBytes(&buffer)  // kdfoptions
        guard cipher == "none" else { throw KeyAuthError.encrypted }

        guard let keyCount: UInt32 = buffer.readInteger(), keyCount >= 1 else { throw KeyAuthError.malformed }
        _ = try readBytes(&buffer)  // public key blob

        var priv = ByteBuffer(bytes: try readBytes(&buffer))
        guard let check1: UInt32 = priv.readInteger(),
              let check2: UInt32 = priv.readInteger(),
              check1 == check2 else {
            throw KeyAuthError.malformed
        }

        let keyType = try readString(&priv)
        switch keyType {
        case "ssh-ed25519":
            _ = try readBytes(&priv)                    // public key (32)
            let secret = try readBytes(&priv)           // 64 = seed(32) + pub(32)
            guard secret.count >= 32 else { throw KeyAuthError.malformed }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(secret.prefix(32)))
            return .ed25519(username: username, privateKey: key)

        case "ecdsa-sha2-nistp256":
            let scalar = try ecdsaScalar(&priv, size: 32)
            return .p256(username: username, privateKey: try P256.Signing.PrivateKey(rawRepresentation: scalar))

        case "ecdsa-sha2-nistp384":
            let scalar = try ecdsaScalar(&priv, size: 48)
            return .p384(username: username, privateKey: try P384.Signing.PrivateKey(rawRepresentation: scalar))

        case "ecdsa-sha2-nistp521":
            let scalar = try ecdsaScalar(&priv, size: 66)
            return .p521(username: username, privateKey: try P521.Signing.PrivateKey(rawRepresentation: scalar))

        case "ssh-rsa", "rsa-sha2-256", "rsa-sha2-512":
            throw KeyAuthError.rsaUnsupported

        default:
            throw KeyAuthError.unsupported(keyType)
        }
    }

    // MARK: - SSH wire helpers (big-endian length-prefixed fields)

    private static func readBytes(_ buffer: inout ByteBuffer) throws -> [UInt8] {
        guard let length: UInt32 = buffer.readInteger(),
              let bytes = buffer.readBytes(length: Int(length)) else {
            throw KeyAuthError.malformed
        }
        return bytes
    }

    private static func readString(_ buffer: inout ByteBuffer) throws -> String {
        String(decoding: try readBytes(&buffer), as: UTF8.self)
    }

    /// ECDSA stores curve name, public point, then the private scalar as an
    /// mpint (may carry a leading zero or be short). Normalise to `size` bytes.
    private static func ecdsaScalar(_ buffer: inout ByteBuffer, size: Int) throws -> Data {
        _ = try readBytes(&buffer)              // curve name
        _ = try readBytes(&buffer)              // public point Q
        var scalar = try readBytes(&buffer)     // private value
        while scalar.count > size, scalar.first == 0 { scalar.removeFirst() }
        if scalar.count < size {
            scalar = Array(repeating: 0, count: size - scalar.count) + scalar
        }
        return Data(scalar)
    }
}
