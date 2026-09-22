import Foundation

/// One saved reading of a provider's windows.
public struct QuotaHistoryPoint: Codable, Sendable, Equatable {
    public let at: Date
    public let provider: Provider
    public let fiveHourPercent: Double?
    public let weeklyPercent: Double?
    /// Busiest monthly window, for providers billed per month (Copilot).
    public let monthlyPercent: Double?

    public init(
        at: Date,
        provider: Provider,
        fiveHourPercent: Double?,
        weeklyPercent: Double?,
        monthlyPercent: Double? = nil
    ) {
        self.at = at
        self.provider = provider
        self.fiveHourPercent = fiveHourPercent
        self.weeklyPercent = weeklyPercent
        self.monthlyPercent = monthlyPercent
    }

    public init(snapshot: QuotaSnapshot) {
        self.init(
            at: snapshot.fetchedAt,
            provider: snapshot.provider,
            fiveHourPercent: snapshot.fiveHour?.usedPercent,
            weeklyPercent: snapshot.weekly?.usedPercent,
            monthlyPercent: snapshot.monthly?.usedPercent
        )
    }

    /// True when the point carries at least one usable number.
    public var hasAnyValue: Bool {
        fiveHourPercent != nil || weeklyPercent != nil || monthlyPercent != nil
    }
}

/// Keeps quota readings on disk so the trend survives a restart.
///
/// One JSON line per reading, in Application Support. A plain file is enough here:
/// the data is small, append-only, and only this app reads it.
public final class QuotaHistoryStore: @unchecked Sendable {
    public static let defaultBundleId = "com.jacobvalter.llmusagemonitor"

    /// Roughly a week at one reading per minute per provider.
    public let maxPoints: Int

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil, maxPoints: Int = 20_000) {
        self.maxPoints = maxPoints
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    public static func defaultFileURL(bundleId: String = defaultBundleId) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleId).appendingPathComponent("quota-history.jsonl")
    }

    public var path: String { fileURL.path }

    // MARK: - Writing

    /// Appends one reading. A snapshot with no windows is skipped.
    public func append(_ snapshot: QuotaSnapshot) {
        let point = QuotaHistoryPoint(snapshot: snapshot)
        guard point.hasAnyValue else { return }
        append(point)
    }

    public func append(_ point: QuotaHistoryPoint) {
        guard let line = try? Self.encoder.encode(point) else { return }

        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line + Data("\n".utf8))
            } else {
                try (line + Data("\n".utf8)).write(to: fileURL, options: .atomic)
            }
        } catch {
            NSLog("QuotaHistoryStore: append failed: \(error)")
        }
    }

    // MARK: - Reading

    public func points(provider: Provider? = nil, since: Date = .distantPast) -> [QuotaHistoryPoint] {
        lock.lock()
        let data = try? Data(contentsOf: fileURL)
        lock.unlock()
        guard let data else { return [] }

        return data
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .compactMap { try? Self.decoder.decode(QuotaHistoryPoint.self, from: Data($0)) }
            .filter { $0.at >= since && (provider == nil || $0.provider == provider) }
    }

    /// Five-hour readings for one provider, oldest first. Feeds the sparkline.
    public func fiveHourSeries(provider: Provider, since: Date = .distantPast) -> [Double] {
        points(provider: provider, since: since).compactMap(\.fiveHourPercent)
    }

    /// Monthly readings for one provider, oldest first.
    public func monthlySeries(provider: Provider, since: Date = .distantPast) -> [Double] {
        points(provider: provider, since: since).compactMap(\.monthlyPercent)
    }

    /// Whichever series that provider actually reports, so the sparkline just works.
    public func primarySeries(provider: Provider, since: Date = .distantPast) -> [Double] {
        let five = fiveHourSeries(provider: provider, since: since)
        return five.isEmpty ? monthlySeries(provider: provider, since: since) : five
    }

    /// Rewrites the file keeping only the newest `maxPoints` lines.
    /// Cheap to call; it returns early when the file is still small.
    public func trimIfNeeded() {
        let all = points()
        guard all.count > maxPoints else { return }
        let kept = Array(all.suffix(maxPoints))

        lock.lock()
        defer { lock.unlock() }
        var blob = Data()
        for p in kept {
            guard let line = try? Self.encoder.encode(p) else { continue }
            blob.append(line)
            blob.append(contentsOf: [UInt8(ascii: "\n")])
        }
        do {
            try blob.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("QuotaHistoryStore: trim failed: \(error)")
        }
    }

    // MARK: - Coders

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
