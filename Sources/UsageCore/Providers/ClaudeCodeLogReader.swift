import Foundation

/// One real assistant message from a Claude Code session log.
public struct ClaudeCodeEntry: Sendable, Equatable {
    /// Unique per API message. Claude Code writes the same message several times
    /// per turn, so this is what stops a 3x over-count.
    public let dedupeKey: String
    public let timestamp: Date
    public let model: String
    public let sessionId: String?
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreationTokens: Int64

    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }
}

/// Summed tokens over a set of entries.
public struct TokenTotals: Sendable, Equatable {
    public var inputTokens: Int64 = 0
    public var outputTokens: Int64 = 0
    public var cacheReadTokens: Int64 = 0
    public var cacheCreationTokens: Int64 = 0
    public var messageCount: Int = 0

    public var totalTokens: Int64 {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    public static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: a.inputTokens + b.inputTokens,
            outputTokens: a.outputTokens + b.outputTokens,
            cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
            cacheCreationTokens: a.cacheCreationTokens + b.cacheCreationTokens,
            messageCount: a.messageCount + b.messageCount
        )
    }
}

/// Remembers parsed files so a refresh only re-reads the session that changed.
/// Keyed on size and modification date, so an edited file is parsed again.
public final class ClaudeCodeLogCache: @unchecked Sendable {
    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: Date
    }

    private let lock = NSLock()
    private var store: [Key: [ClaudeCodeEntry]] = [:]

    public init() {}

    func entries(path: URL, size: Int, modified: Date, parse: () -> [ClaudeCodeEntry]) -> [ClaudeCodeEntry] {
        let key = Key(path: path.path, size: size, modified: modified)
        lock.lock()
        if let hit = store[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let parsed = parse()

        lock.lock()
        // Drop older versions of this same file.
        store = store.filter { $0.key.path != key.path }
        store[key] = parsed
        lock.unlock()
        return parsed
    }

    public func clear() {
        lock.lock(); store.removeAll(); lock.unlock()
    }
}

/// Reads token counts from `~/.claude/projects/**/*.jsonl`.
///
/// Two things make this non-obvious:
///  - the same message is written once per tool-use step in a turn, always with the
///    same cumulative usage, so entries must be deduped by message id;
///  - `<synthetic>` records are local error placeholders and cost nothing.
public struct ClaudeCodeLogReader: Sendable {
    public static let syntheticModel = "<synthetic>"

    private let projectsDirectory: URL
    private let cache: ClaudeCodeLogCache?

    public init(
        projectsDirectory: URL? = nil,
        cache: ClaudeCodeLogCache? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.cache = cache
        if let projectsDirectory {
            self.projectsDirectory = projectsDirectory
        } else {
            let base = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude")
            self.projectsDirectory = base.appendingPathComponent("projects")
        }
    }

    /// Every deduped assistant message at or after `since`.
    /// Files untouched since that date are skipped without being opened.
    public func entries(since: Date) -> [ClaudeCodeEntry] {
        var seen = Set<String>()
        var out: [ClaudeCodeEntry] = []

        for file in logFiles(modifiedSince: since) {
            for entry in parsed(file) where entry.timestamp >= since {
                if seen.insert(entry.dedupeKey).inserted {
                    out.append(entry)
                }
            }
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }

    private func parsed(_ file: URL) -> [ClaudeCodeEntry] {
        let read = { () -> [ClaudeCodeEntry] in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return [] }
            return Self.parse(data)
        }
        guard let cache,
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return read() }

        return cache.entries(path: file, size: size, modified: modified, parse: read)
    }

    /// Session files whose contents could include something at or after `since`.
    func logFiles(modifiedSince: Date) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: projectsDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if let modified = values?.contentModificationDate, modified < modifiedSince { continue }
            files.append(url)
        }
        return files
    }

    // MARK: - Parsing

    /// Parses a whole `.jsonl` blob. Does not dedupe; `entries(since:)` does that across files.
    public static func parse(_ data: Data) -> [ClaudeCodeEntry] {
        var out: [ClaudeCodeEntry] = []
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).forEach { slice in
            // Cheap reject before the JSON parser: most lines are not assistant records.
            guard slice.count > 2, slice.firstRange(of: Array("\"type\":\"assistant\"".utf8)) != nil else { return }
            if let entry = parseLine(Data(slice)) { out.append(entry) }
        }
        return out
    }

    /// Parses one JSONL line. Returns nil for anything that is not a billable message.
    public static func parseLine(_ line: Data) -> ClaudeCodeEntry? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "assistant",
              let message = root["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let model = message["model"] as? String ?? ""
        guard !model.isEmpty, model != syntheticModel else { return nil }

        guard let stamp = root["timestamp"] as? String, let timestamp = DateParsing.date(from: stamp) else {
            return nil
        }

        // message.id is the API's own id; requestId disambiguates the rare retry.
        let messageId = message["id"] as? String
        let requestId = root["requestId"] as? String
        guard let key = messageId ?? requestId else { return nil }

        func int(_ key: String) -> Int64 {
            (usage[key] as? NSNumber)?.int64Value ?? 0
        }

        // cache_creation_input_tokens is the flat mirror of cache_creation.*; prefer it.
        var cacheCreation = int("cache_creation_input_tokens")
        if cacheCreation == 0, let nested = usage["cache_creation"] as? [String: Any] {
            cacheCreation = ((nested["ephemeral_5m_input_tokens"] as? NSNumber)?.int64Value ?? 0)
                + ((nested["ephemeral_1h_input_tokens"] as? NSNumber)?.int64Value ?? 0)
        }

        return ClaudeCodeEntry(
            dedupeKey: "\(key)|\(requestId ?? "")",
            timestamp: timestamp,
            model: model,
            sessionId: root["sessionId"] as? String,
            inputTokens: int("input_tokens"),
            outputTokens: int("output_tokens"),
            cacheReadTokens: int("cache_read_input_tokens"),
            cacheCreationTokens: cacheCreation
        )
    }

    // MARK: - Aggregation

    public static func totals(_ entries: [ClaudeCodeEntry]) -> TokenTotals {
        entries.reduce(into: TokenTotals()) { acc, e in
            acc.inputTokens += e.inputTokens
            acc.outputTokens += e.outputTokens
            acc.cacheReadTokens += e.cacheReadTokens
            acc.cacheCreationTokens += e.cacheCreationTokens
            acc.messageCount += 1
        }
    }

    /// Per-model totals, busiest first.
    public static func byModel(_ entries: [ClaudeCodeEntry]) -> [(model: String, totals: TokenTotals)] {
        Dictionary(grouping: entries, by: \.model)
            .map { (model: $0.key, totals: totals($0.value)) }
            .sorted { $0.totals.totalTokens > $1.totals.totalTokens }
    }

    /// Total tokens per hour for the last `hours`, oldest first. Feeds the sparkline.
    public static func hourlyTotals(
        _ entries: [ClaudeCodeEntry],
        hours: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Int64] {
        guard hours > 0 else { return [] }
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var buckets = [Int64](repeating: 0, count: hours)
        for e in entries {
            let hoursAgo = Int(currentHour.timeIntervalSince(
                calendar.dateInterval(of: .hour, for: e.timestamp)?.start ?? e.timestamp
            ) / 3600)
            let index = hours - 1 - hoursAgo
            if index >= 0, index < hours { buckets[index] += e.totalTokens }
        }
        return buckets
    }
}
