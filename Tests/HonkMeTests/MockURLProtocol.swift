import Foundation
@testable import HonkMe

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A scripted answer: an HTTP response (optionally delayed) or a dropped connection.
enum Step: Sendable {
    case respond(status: Int, headers: [String: String] = [:], body: String = "", delay: Duration = .zero)
    case fail(URLError.Code)

    static func accepted(duplicate: Bool = false) -> Step {
        .respond(status: 202, body: #"{"id":"msg_01k6h3w4z5x6y7z8a9b0c1d2e3","status":"accepted","duplicate":\#(duplicate),"received_at":"2026-10-02T21:10:00.123Z"}"#)
    }

    static func error(_ status: Int, _ code: String, retryAfter: String? = nil, extra: String = "") -> Step {
        .respond(
            status: status,
            headers: retryAfter.map { ["Retry-After": $0] } ?? [:],
            body: #"{"error":{"code":"\#(code)","message":"\#(code) happened","request_id":"req_test"\#(extra)}}"#
        )
    }
}

struct Recorded: Sendable {
    let url: URL
    let headers: [String: String]
    let body: Data
    let at: ContinuousClock.Instant

    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
}

/// Answers every request with the next step of the script (the last one repeats).
final class MockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [Step] = [.accepted()]
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private var cancelled = false

    static func script(_ steps: [Step]) {
        lock.withLock {
            self.steps = steps
            self.recorded = []
        }
    }

    static var requests: [Recorded] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let step: Step = Self.lock.withLock {
            let n = Self.recorded.count
            Self.recorded.append(Recorded(url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body, at: .now))
            return Self.steps[min(n, Self.steps.count - 1)]
        }
        switch step {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .respond(let status, let headers, let text, let delay):
            // URLProtocol is not Sendable on Linux; the box only hands it to the delayed callback.
            let box = UncheckedBox(self)
            let respond: @Sendable () -> Void = {
                let proto = box.value
                guard !MockURLProtocol.lock.withLock({ proto.cancelled }) else { return }
                let response = HTTPURLResponse(url: proto.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
                proto.client?.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                proto.client?.urlProtocol(proto, didLoad: Data(text.utf8))
                proto.client?.urlProtocolDidFinishLoading(proto)
            }
            if delay == .zero {
                respond()
            } else {
                let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: respond)
            }
        }
    }

    override func stopLoading() {
        Self.lock.withLock { cancelled = true }
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

let testKey = "honk_ab12cd34ef56_0123456789abcdefghijABCDEFGHIJ0123"

func mockConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return configuration
}

func mockClient(
    timeout: Duration = .seconds(5), retries: Int = 4, deadline: Duration = .seconds(30), defaults: Defaults = Defaults(), validate: Bool = true
) throws -> Honk {
    try Honk(
        url: "https://honk.test", key: testKey, timeout: timeout, retries: retries, deadline: deadline, defaults: defaults,
        validate: validate, backoff: Backoff(base: .milliseconds(1), max: .milliseconds(5)), configuration: mockConfiguration()
    )
}
