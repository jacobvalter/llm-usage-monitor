import Foundation
import XCTest

/// Records requests and replays canned responses in order (the last one repeats).
/// A class with a lock so it can be mutated from inside a `@Sendable` closure.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func respond(
        with bodies: [String],
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        return { [self] request in
            let index: Int
            lock.lock()
            _requests.append(request)
            index = min(_requests.count - 1, bodies.count - 1)
            lock.unlock()
            let body = bodies[index].data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (body, response)
        }
    }
}

extension XCTestCase {
    func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
                                "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    func isoDate(_ s: String) -> Date {
        ISO8601DateFormatter().date(from: s)!
    }

    func queryItems(_ url: URL) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            out[item.name, default: []].append(item.value ?? "")
        }
        return out
    }
}
