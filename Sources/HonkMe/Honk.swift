import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Client for `POST /v1/messages`. Create one per process and reuse it: it owns a URLSession,
/// so connections are kept alive.
///
/// ```swift
/// let honk = try Honk(url: "https://honk.example.com", key: secret)
/// try await honk.beep("Backup finished", "nightly pg_dump took 42 s")
/// ```
///
/// The ingestion key is a server-side secret: use this package in server-side Swift (Vapor,
/// Hummingbird), macOS tools and CLIs, never inside an app you ship to users.
public final class Honk: Sendable {
    public static let version = "0.1.0"

    /// Base URL of the Honk server.
    public let url: URL
    public let timeout: Duration
    public let retries: Int
    public let deadline: Duration
    public let defaults: Defaults
    public let validates: Bool
    public let backoff: Backoff
    private let key: String
    private let session: URLSession
    private let userAgent: String

    /// - Parameters:
    ///   - url: base address of your Honk server, e.g. `https://honk.example.com`.
    ///   - key: a project ingestion key (`honk_…`). Keep it on the server.
    ///   - timeout: one HTTP attempt.
    ///   - retries: retries after the first attempt (network errors, 429 and 5xx only).
    ///   - deadline: total budget of one send, waits included.
    ///   - defaults: source / environment / channel for messages that leave them unset.
    ///   - validate: check messages locally before sending (the server always validates).
    ///   - configuration: the URLSession configuration (proxies, test protocols). Redirects are
    ///     never followed.
    public init(
        url: String,
        key: String,
        timeout: Duration = .seconds(5),
        retries: Int = 4,
        deadline: Duration = .seconds(30),
        defaults: Defaults = Defaults(),
        validate: Bool = true,
        backoff: Backoff = Backoff(),
        configuration: URLSessionConfiguration = .ephemeral,
        userAgent: String? = nil
    ) throws(HonkError) {
        var base = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1/messages") { base.removeLast("/v1/messages".count) }
        guard !base.isEmpty else {
            throw .invalidConfiguration("url is required (the base address of your Honk server, e.g. https://honk.example.com; is HONK_URL set?)")
        }
        let lower = base.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), let parsed = URL(string: base), parsed.host != nil else {
            throw .invalidConfiguration("url must start with https:// (got \"\(url)\")")
        }
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else {
            throw .invalidConfiguration("key is required (a project ingestion key honk_…; is HONK_KEY set?)")
        }
        guard k.hasPrefix("honk_"), k.utf8.allSatisfy({ (0x21...0x7E).contains($0) }) else {
            throw .invalidConfiguration("key must be a project ingestion key starting with honk_ (create one under Project → Keys)")
        }
        guard retries >= 0, timeout > .zero, deadline > .zero, backoff.base > .zero, backoff.max > .zero else {
            throw .invalidConfiguration("timeout, deadline and backoff must be positive, retries ≥ 0")
        }
        self.url = parsed
        self.key = k
        self.timeout = timeout
        self.retries = retries
        self.deadline = deadline
        self.defaults = defaults
        self.validates = validate
        self.backoff = backoff
        self.userAgent = "honk-me-swift/\(Honk.version)" + (userAgent.map { " \($0)" } ?? "")
        self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Reads `HONK_URL`, `HONK_KEY` and the optional `HONK_SOURCE`, `HONK_ENVIRONMENT`,
    /// `HONK_CHANNEL` defaults.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: Duration = .seconds(5),
        retries: Int = 4,
        deadline: Duration = .seconds(30),
        configuration: URLSessionConfiguration = .ephemeral
    ) throws(HonkError) -> Honk {
        try Honk(
            url: environment["HONK_URL"] ?? "",
            key: environment["HONK_KEY"] ?? "",
            timeout: timeout,
            retries: retries,
            deadline: deadline,
            defaults: Defaults(source: environment["HONK_SOURCE"], environment: environment["HONK_ENVIRONMENT"], channel: environment["HONK_CHANNEL"]),
            configuration: configuration
        )
    }

    /// Sends one event and returns once Honk has durably stored it (202), which does not mean a
    /// push was delivered. Network errors, timeouts, 429 and 5xx are retried with the same
    /// Idempotency-Key until `retries` or `deadline` runs out.
    ///
    /// - Parameter idempotencyKey: a stable key for this event (1–128 printable ASCII
    ///   characters), e.g. "request-4812". Default: a new UUIDv7, reused on every retry.
    /// - Throws: `HonkError`, or `CancellationError` when the task is cancelled.
    @discardableResult
    public func send(_ message: Message, idempotencyKey: String? = nil) async throws -> Accepted {
        let body = try Wire.encode(message, defaults: defaults, validate: validates)
        let key = idempotencyKey ?? UUIDv7.make()
        guard Wire.validIdempotencyKey(key) else {
            throw Wire.localValidation([FieldError(field: "Idempotency-Key", code: "invalid_format", message: "use 1-128 printable ASCII characters without spaces, e.g. \"request-4812\"")])
        }
        var request = URLRequest(url: url.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(self.key)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let clock = ContinuousClock()
        let deadlineInstant = clock.now.advanced(by: deadline)
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadlineInstant)
            let attemptTimeout = max(.milliseconds(1), min(timeout, remaining))
            let failure: HonkError
            do {
                let (data, response) = try await perform(request, timeout: attemptTimeout)
                if (200..<300).contains(response.statusCode) {
                    return try Self.accepted(data, status: response.statusCode, key: key, attempts: attempt)
                }
                failure = Self.error(for: response, data: data, key: key, attempts: attempt)
            } catch let error as HonkError {
                failure = error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                failure = Self.networkError(error, key: key, attempts: attempt, timeout: attemptTimeout)
            }
            guard failure.isRetryable, attempt <= retries else { throw failure }
            let ceiling = min(backoff.max, backoff.base * (1 << min(attempt - 1, 30)))
            let jitter = Duration.nanoseconds(Int64.random(in: 0...max(0, ceiling.nanoseconds)))
            let wait = max(jitter, failure.failure?.retryAfter ?? .zero)
            if clock.now.advanced(by: wait) >= deadlineInstant { throw failure }
            try await Task.sleep(for: wait)
        }
    }

    // MARK: Helpers

    /// A problem for `groupKey` (opens or continues its incident). Severity defaults to `.long` (error).
    @discardableResult
    public func problem(groupKey: String, _ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        var m = Message(message, title: title, severity: .long)
        configure(&m)
        m.groupKey = groupKey
        m.eventType = .problem
        return try await send(m, idempotencyKey: idempotencyKey)
    }

    /// A recovery for `groupKey` (closes its open incident). Severity defaults to `.beep` (success).
    @discardableResult
    public func recovery(groupKey: String, _ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        var m = Message(message, title: title, severity: .beep)
        configure(&m)
        m.groupKey = groupKey
        m.eventType = .recovery
        return try await send(m, idempotencyKey: idempotencyKey)
    }

    /// A light honk (info).
    @discardableResult
    public func light(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.info, title, message, idempotencyKey, configure)
    }

    /// A beep-beep (success).
    @discardableResult
    public func beep(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.success, title, message, idempotencyKey, configure)
    }

    /// A loud honk (warning).
    @discardableResult
    public func loud(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.warning, title, message, idempotencyKey, configure)
    }

    /// A long honk (error; pushes at least as high priority).
    @discardableResult
    public func long(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.error, title, message, idempotencyKey, configure)
    }

    /// A blast (critical; pushes at least as high priority).
    @discardableResult
    public func blast(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.critical, title, message, idempotencyKey, configure)
    }

    /// Synonym of `light`.
    @discardableResult
    public func info(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.info, title, message, idempotencyKey, configure)
    }

    /// Synonym of `beep`.
    @discardableResult
    public func success(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.success, title, message, idempotencyKey, configure)
    }

    /// Synonym of `loud`.
    @discardableResult
    public func warning(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.warning, title, message, idempotencyKey, configure)
    }

    /// Synonym of `long`.
    @discardableResult
    public func error(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.error, title, message, idempotencyKey, configure)
    }

    /// Synonym of `blast`.
    @discardableResult
    public func critical(_ title: String?, _ message: String, idempotencyKey: String? = nil, _ configure: (inout Message) -> Void = { _ in }) async throws -> Accepted {
        try await send(.critical, title, message, idempotencyKey, configure)
    }

    private func send(_ severity: Severity, _ title: String?, _ message: String, _ key: String?, _ configure: (inout Message) -> Void) async throws -> Accepted {
        var m = Message(message, title: title)
        configure(&m)
        m.severity = severity
        return try await send(m, idempotencyKey: key)
    }

    // MARK: Transport

    private func perform(_ request: URLRequest, timeout: Duration) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let session = self.session
        let sendable = SendableRequest(request: request)
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse)?.self) { group in
            group.addTask {
                let (data, response) = try await session.data(for: sendable.request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let result = first else {
                throw AttemptTimeout()
            }
            return result
        }
    }

    private static func accepted(_ data: Data, status: Int, key: String, attempts: Int) throws(HonkError) -> Accepted {
        struct Body: Decodable {
            let id: String
            let duplicate: Bool?
            let received_at: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else {
            throw .http(.init(status: status, message: "answer without a message id", idempotencyKey: key, attempts: attempts))
        }
        let received = body.received_at.flatMap { try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) }
            ?? body.received_at.flatMap { try? Date($0, strategy: .iso8601) }
            ?? Date()
        return Accepted(id: body.id, duplicate: body.duplicate ?? false, receivedAt: received)
    }

    static func error(for response: HTTPURLResponse, data: Data, key: String, attempts: Int) -> HonkError {
        struct Envelope: Decodable {
            struct Body: Decodable {
                let code: String?
                let message: String?
                let request_id: String?
                let fields: [FieldError]?
            }
            let error: Body?
        }
        let body = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
        let status = response.statusCode
        var text = body?.message ?? String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = HTTPURLResponse.localizedString(forStatusCode: status) }
        var failure = HonkError.Failure(
            status: status, code: body?.code, message: text, fields: body?.fields ?? [],
            requestID: body?.request_id ?? response.value(forHTTPHeaderField: "X-Request-ID"),
            idempotencyKey: key, attempts: attempts,
            retryAfter: parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
        )
        switch status {
        case 400, 413, 415, 422: return .validation(failure)
        case 401, 403: return .auth(failure)
        case 409: return .conflict(failure)
        case 429: return .quota(failure)
        case 500...: return .server(failure)
        case 300..<400:
            failure.message = "redirect"
                + (response.value(forHTTPHeaderField: "Location").map { " to \($0)" } ?? "")
                + "; set url to the final https address"
            return .http(failure)
        case 404:
            failure.message += " (is url the base address of your Honk server?)"
            return .http(failure)
        default: return .http(failure)
        }
    }

    private static func networkError(_ error: any Error, key: String, attempts: Int, timeout: Duration) -> HonkError {
        if error is AttemptTimeout || (error as? URLError)?.code == .timedOut {
            return .timeout(.init(code: "timeout", message: "no answer within \(timeout) (the event may or may not have been stored; retrying with the same idempotency key is safe)", idempotencyKey: key, attempts: attempts))
        }
        return .network(.init(code: "network_error", message: "could not reach Honk: \(error.localizedDescription)", idempotencyKey: key, attempts: attempts))
    }

    /// Delta-seconds or an HTTP date; nil when absent or invalid.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> Duration? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let seconds = Int(v), seconds >= 0 { return .seconds(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: v) else { return nil }
        return .seconds(max(0, Int(date.timeIntervalSince(now).rounded())))
    }
}

private struct AttemptTimeout: Error {}

private struct SendableRequest: @unchecked Sendable {
    let request: URLRequest
}

/// Redirects are reported (as `.http`), never followed: a POST must not silently become a GET.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension Duration {
    fileprivate var nanoseconds: Int64 {
        components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }
}
