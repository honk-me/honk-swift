import Foundation

/// One invalid field, from the server (`error.fields[]`) or local validation.
public struct FieldError: Sendable, Equatable, Codable {
    /// Wire name: `group_key`, `metadata.region`, `Idempotency-Key`, `body`, …
    public let field: String
    /// `required`, `too_long`, `too_short`, `invalid_enum`, `invalid_format`, `out_of_range`,
    /// `not_allowed`, `requires_group_key`, …
    public let code: String
    public let message: String?

    public init(field: String, code: String, message: String? = nil) {
        self.field = field
        self.code = code
        self.message = message
    }
}

/// Errors thrown by `Honk`. Cancellation of the calling task throws `CancellationError` instead.
///
/// ```swift
/// do { try await honk.loud("Disk 91%", "/var on app-01") }
/// catch HonkError.quota(let failure) { retry(after: failure.retryAfter) }
/// catch let error as HonkError where error.isRetryable { requeue(key: error.failure?.idempotencyKey) }
/// ```
public enum HonkError: Error, Sendable, CustomStringConvertible, LocalizedError {
    /// The URL or key passed to `Honk(url:key:)` is missing or malformed.
    case invalidConfiguration(String)
    /// The message is invalid: rejected locally (`isLocal`) or by the server (400, 413, 415, 422).
    case validation(Failure)
    /// 401/403: invalid or revoked key, `priority_not_allowed`, suspended project or workspace.
    case auth(Failure)
    /// 429 after retries: `quota_exceeded` (daily, until UTC midnight) or `rate_limited`. See `retryAfter`.
    case quota(Failure)
    /// 409 `idempotency_conflict`: the key was already used with a different payload in the last 24 hours.
    case conflict(Failure)
    /// Honk could not be reached on any attempt before the deadline.
    case network(Failure)
    /// Attempts timed out; the message may or may not have been stored (retrying with the same key is safe).
    case timeout(Failure)
    /// 5xx on every attempt before the deadline.
    case server(Failure)
    /// Any other unexpected answer (404 wrong URL, a redirect, a malformed 202).
    case http(Failure)

    /// Details of a failed send.
    public struct Failure: Sendable, Equatable {
        /// HTTP status, when the server answered.
        public var status: Int?
        /// API error code (`invalid_key`, `quota_exceeded`, …) or `network_error` / `timeout` / `validation_failed`.
        public var code: String?
        public var message: String
        /// Every invalid field, for `.validation`.
        public var fields: [FieldError]
        /// True when the SDK rejected the message before sending anything.
        public var isLocal: Bool
        public var requestID: String?
        /// The Idempotency-Key that was used; retry later with it to stay duplicate-free.
        public var idempotencyKey: String?
        /// HTTP attempts made.
        public var attempts: Int
        /// The server's Retry-After, when present.
        public var retryAfter: Duration?

        public init(
            status: Int? = nil, code: String? = nil, message: String, fields: [FieldError] = [], isLocal: Bool = false,
            requestID: String? = nil, idempotencyKey: String? = nil, attempts: Int = 0, retryAfter: Duration? = nil
        ) {
            self.status = status
            self.code = code
            self.message = message
            self.fields = fields
            self.isLocal = isLocal
            self.requestID = requestID
            self.idempotencyKey = idempotencyKey
            self.attempts = attempts
            self.retryAfter = retryAfter
        }
    }

    /// The failure details (nil for `.invalidConfiguration`).
    public var failure: Failure? {
        switch self {
        case .invalidConfiguration: nil
        case .validation(let f), .auth(let f), .quota(let f), .conflict(let f), .network(let f), .timeout(let f),
            .server(let f), .http(let f):
            f
        }
    }

    /// True when sending the same event again later (with the same idempotency key) may succeed.
    public var isRetryable: Bool {
        switch self {
        case .network, .timeout, .server, .quota: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .invalidConfiguration(let message):
            return "Honk: \(message)"
        default:
            guard let f = failure else { return "Honk error" }
            var text = "Honk"
            if let status = f.status { text += " \(status)" }
            if let code = f.code, f.status != nil { text += " \(code)" }
            text += ": \(f.message)"
            if !f.fields.isEmpty {
                text += " (" + f.fields.map { "\($0.field) \($0.message ?? $0.code)" }.joined(separator: "; ") + ")"
            }
            return text
        }
    }

    public var errorDescription: String? { description }
}
