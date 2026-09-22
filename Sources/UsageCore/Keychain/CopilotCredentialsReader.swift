import Foundation

/// Finds a GitHub token for the Copilot quota endpoint, without storing one of our own.
///
/// Order: `GH_TOKEN`, `GITHUB_TOKEN`, then `gh auth token`.
/// The gh CLI keeps its token in the Keychain, so shelling out to it is the
/// supported way to read it and avoids a second credential prompt.
public struct CopilotCredentialsReader: Sendable {
    public static let dotComHost = "github.com"

    /// nil means github.com. Otherwise a GitHub Enterprise hostname.
    public let host: String?

    private let environment: [String: String]
    private let ghTokenProvider: @Sendable (String?) -> String?

    public init(
        host: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        ghTokenProvider: @escaping @Sendable (String?) -> String? = { CopilotCredentialsReader.tokenFromGHCLI(host: $0) }
    ) {
        self.host = host
        self.environment = environment
        self.ghTokenProvider = ghTokenProvider
    }

    /// Where to send Copilot requests for this host.
    ///   github.com          -> https://api.github.com
    ///   acme.ghe.com        -> https://api.acme.ghe.com   (Enterprise Cloud w/ data residency)
    ///   git.example.com     -> https://git.example.com/api/v3  (Enterprise Server)
    public var apiBaseURL: URL {
        Self.apiBaseURL(for: host)
    }

    public static func apiBaseURL(for host: String?) -> URL {
        guard let host, !host.isEmpty, host != dotComHost else {
            return URL(string: "https://api.github.com")!
        }
        if host.hasSuffix(".ghe.com") {
            return URL(string: "https://api.\(host)")!
        }
        return URL(string: "https://\(host)/api/v3")!
    }

    /// Environment tokens only apply to github.com; an enterprise seat needs its own token.
    public func loadToken() throws -> String {
        if host == nil || host == Self.dotComHost {
            for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
                if let token = environment[key], !token.isEmpty { return token }
            }
        }
        if let token = ghTokenProvider(host), !token.isEmpty { return token }
        throw CopilotError.noCredentials
    }

    /// The first non-github.com host the gh CLI is logged into, if any.
    public static func enterpriseHost(configDirectory: URL? = nil) -> String? {
        let dir = configDirectory
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/gh")
        guard let text = try? String(contentsOf: dir.appendingPathComponent("hosts.yml"), encoding: .utf8) else {
            return nil
        }
        return parseHosts(text).first { $0 != dotComHost }
    }

    /// Top-level keys of gh's hosts.yml, which are the hostnames.
    static func parseHosts(_ yaml: String) -> [String] {
        yaml.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard !line.hasPrefix(" "), !line.hasPrefix("#"), !line.hasPrefix("-"),
                  let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            return name.contains(".") ? name : nil
        }
    }

    /// `gh auth token`, optionally for a specific host.
    /// Returns nil when gh is missing or not logged into that host.
    public static func tokenFromGHCLI(host: String? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["gh", "auth", "token"]
        if let host, !host.isEmpty { args += ["--hostname", host] }
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (token?.isEmpty == false) ? token : nil
    }
}
