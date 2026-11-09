import Foundation

/// ISO 8601 timestamps as used on the wire: `2026-11-09T14:00:00.000Z`.
enum WireDate {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    static func format(_ date: Date) -> String {
        date.formatted(withFraction)
    }

    static func parse(_ string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? withoutFraction.parse(string))
    }
}
