import Foundation

/// Words the core shows (list groups) in the interface language. PeroKit has no
/// localized resources of its own: the app fills these in at launch.
public enum PeroStrings {
    public static var localize: (String) -> String = { $0 }
    public static var locale = Locale(identifier: "ru_RU")
}
