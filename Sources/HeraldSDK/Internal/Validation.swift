import Foundation

/// Client-side copies of the server's batch limits (herald `src/lib/sdk/schema.ts`). The server rejects
/// a whole batch for one bad event, so a bad call is refused before it is queued. Lengths count UTF-16
/// code units, as JavaScript (and Zod's `.max()`) does. Each check returns a problem, or nil when valid.
enum Validation {
    static let maxName = 255
    static let maxUserId = 200
    static let maxMessageId = 200
    static let maxPushToken = 4096

    static func length(_ field: String, _ value: String, min: Int = 1, max: Int) -> String? {
        let count = value.utf16.count
        if count < min { return "\(field) must not be empty" }
        if count > max { return "\(field) is longer than \(max) characters" }
        return nil
    }

    /// Traits and attributes: keys 1–255, values string, finite number, bool, null or string array.
    /// `$email` / `$phone`, when strings, must pass the server's email / E.164 checks.
    static func attributes(_ field: String, _ map: [String: HeraldValue]) -> String? {
        for (key, value) in map {
            if let problem = length("\(field) key", key, max: maxName) { return problem }
            switch value {
            case .string, .bool, .null: break
            case .number(let number) where number.isFinite: break
            case .array(let items) where items.allSatisfy({ $0.stringValue != nil }): break
            default: return "\(field) '\(key)' must be a string, number, boolean, null or array of strings"
            }
            if key == "$email", let email = value.stringValue, !isValidEmail(email) { return "$email is not a valid email" }
            if key == "$phone", let phone = value.stringValue, !isValidPhone(phone) {
                return "$phone must be E.164, for example +15551234567"
            }
        }
        return nil
    }

    /// Event properties: keys up to 255; any JSON value, but numbers must be finite.
    static func properties(_ field: String, _ map: [String: HeraldValue]) -> String? {
        for (key, value) in map {
            if let problem = length("\(field) key", key, min: 0, max: maxName) { return problem }
            if !isFinite(value) { return "\(field) '\(key)' contains a number that is not finite" }
        }
        return nil
    }

    /// Zod 4's email regex (`z.string().email()`), applied to the trimmed value as the server does.
    static func isValidEmail(_ value: String) -> Bool {
        let pattern = #"^(?!\.)(?!.*\.\.)([A-Za-z0-9_'+\-\.]*)[A-Za-z0-9_+-]@([A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}$"#
        return value.trimmingCharacters(in: .whitespacesAndNewlines).range(of: pattern, options: .regularExpression) != nil
    }

    static func isValidPhone(_ value: String) -> Bool {
        value.range(of: #"^\+[1-9][0-9]{6,14}$"#, options: .regularExpression) != nil
    }

    private static func isFinite(_ value: HeraldValue) -> Bool {
        switch value {
        case .number(let number): return number.isFinite
        case .array(let items): return items.allSatisfy(isFinite)
        case .object(let object): return object.values.allSatisfy(isFinite)
        default: return true
        }
    }

    /// Longest prefix whose UTF-16 length is at most `max`, never splitting a character.
    static func truncated(_ value: String, _ max: Int) -> String {
        guard value.utf16.count > max else { return value }
        var result = ""
        var count = 0
        for character in value {
            let size = character.utf16.count
            if count + size > max { break }
            result.append(character)
            count += size
        }
        return result
    }
}
