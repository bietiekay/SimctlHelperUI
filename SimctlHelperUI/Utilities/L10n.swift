import Foundation

enum L10n {
    nonisolated static func t(_ key: String) -> String {
        NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: key,
            comment: ""
        )
    }

    nonisolated static func f(_ key: String, _ args: CVarArg...) -> String {
        let format = t(key)
        return String(format: format, locale: Locale.current, arguments: args)
    }
}
