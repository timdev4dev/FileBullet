import Foundation

/// Supported UI languages. English is the default fallback.
enum AppLanguage {
    case en, ru, de, es
}

enum L10n {
    /// Resolved once from the system's preferred languages; English if none match.
    static let current: AppLanguage = {
        for identifier in Locale.preferredLanguages {
            switch String(identifier.prefix(2)).lowercased() {
            case "ru": return .ru
            case "de": return .de
            case "es": return .es
            case "en": return .en
            default: continue
            }
        }
        return .en
    }()
}

/// Pick a localized string for the current system language (English default).
func loc(_ en: String, _ ru: String, _ de: String, _ es: String) -> String {
    switch L10n.current {
    case .en: return en
    case .ru: return ru
    case .de: return de
    case .es: return es
    }
}
