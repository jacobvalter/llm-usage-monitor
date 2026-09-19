import Foundation

/// Tolerant RFC 3339 / ISO 8601 parsing for the assorted timestamp shapes the
/// provider APIs return:
///   "2026-09-19T12:00:00Z"
///   "2026-09-19T12:00:00.528Z"
///   "2026-04-11T07:00:00.528743+00:00"   (microseconds + explicit offset)
enum DateParsing {
    static func date(from string: String) -> Date? {
        if let d = internet.date(from: string) { return d }
        if let d = internetFractional.date(from: string) { return d }
        // ISO8601DateFormatter only accepts millisecond precision; trim longer fractions.
        if let trimmed = trimFraction(string, toDigits: 3), let d = internetFractional.date(from: trimmed) {
            return d
        }
        return nil
    }

    static func rfc3339(_ date: Date) -> String {
        internet.string(from: date)
    }

    private static var internet: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private static var internetFractional: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// "…:00.528743+00:00" → "…:00.528+00:00"
    private static func trimFraction(_ s: String, toDigits n: Int) -> String? {
        guard let dot = s.lastIndex(of: ".") else { return nil }
        let after = s[s.index(after: dot)...]
        let digitsEnd = after.firstIndex { !$0.isNumber } ?? after.endIndex
        let digits = after[after.startIndex..<digitsEnd]
        guard digits.count > n else { return nil }
        return String(s[...dot]) + digits.prefix(n) + String(after[digitsEnd...])
    }
}
