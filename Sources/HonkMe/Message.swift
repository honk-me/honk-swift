import Foundation

/// Severity of a message, lowest to highest. Every case has a horn name on the Honk scale; the
/// horn names are aliases of the canonical cases: `Severity.loud == .warning`.
///
/// `long` (error) and `blast` (critical) push at least as high priority.
public enum Severity: String, Sendable, CaseIterable, Codable {
    case info, success, warning, error, critical

    /// A light honk.
    public static let light: Severity = .info
    /// A beep-beep.
    public static let beep: Severity = .success
    /// A loud honk.
    public static let loud: Severity = .warning
    /// A long honk.
    public static let long: Severity = .error
    /// A blast.
    public static let blast: Severity = .critical

    /// Horn name → canonical severity.
    public static let aliases: [String: Severity] = [
        "light": .info, "beep": .success, "loud": .warning, "long": .error, "blast": .critical,
    ]

    /// Parses a canonical name or horn name, case-insensitively: `Severity(parsing: "LOUD") == .warning`.
    public init?(parsing value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let canonical = Severity(rawValue: v) {
            self = canonical
        } else if let alias = Severity.aliases[v] {
            self = alias
        } else {
            return nil
        }
    }

    /// The horn name: light, beep, loud, long or blast.
    public var horn: String {
        switch self {
        case .info: "light"
        case .success: "beep"
        case .warning: "loud"
        case .error: "long"
        case .critical: "blast"
        }
    }
}

/// Declared priority. `urgent` needs an ingestion key with "allow urgent".
public enum Priority: String, Sendable, CaseIterable, Codable {
    case low, normal, high, urgent
}

/// `problem` opens an incident for its group, `recovery` closes it; both need a group key.
public enum EventType: String, Sendable, CaseIterable, Codable {
    case event, problem, recovery
}

/// Category taxonomy v1.
public enum Category: String, Sendable, CaseIterable, Codable {
    case infrastructure, security, backups, deployments, payments, customers, sales, automation, personal, other
}

/// A metadata value: a string (≤ 512 characters), a number or a boolean. Literals work:
/// `["host": "app-01", "attempts": 3, "retried": true]`.
public enum MetadataValue: Sendable, Equatable, Codable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else {
            self = .string(try c.decode(String.self))
        }
    }
}

/// A button on a message: `Action(title: "Call Emily", url: "tel:+15550134")`. Honk never opens
/// the URL; the phone does, when you tap the button.
public struct Action: Sendable, Equatable, Hashable, Codable {
    /// 1–40 characters, one line, shown as sent.
    public var title: String
    /// `https://` (no credentials), `mailto:`, `tel:` or `sms:`, ≤ 2048 bytes.
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// One event for `POST /v1/messages`. Only `message` is required; nil fields are omitted, so the
/// server defaults apply (severity info, priority normal, source "api", environment "default",
/// channel "general", event type event, TTL 3600 s).
public struct Message: Sendable, Equatable {
    /// Plain text, 1–8192 bytes of UTF-8. Line breaks and tabs are allowed.
    public var message: String
    /// One line, ≤ 160 characters. Defaults to the first line of `message`.
    public var title: String?
    /// The Honk scale: `.light`, `.beep`, `.loud`, `.long`, `.blast` (or the canonical names).
    public var severity: Severity?
    public var priority: Priority?
    public var category: Category?
    /// ≤ 64 characters. Default: the client's `defaults.source`, else "api".
    public var source: String?
    /// ≤ 32 characters.
    public var environment: String?
    /// ≤ 64 characters.
    public var channel: String?
    /// ≤ 128 characters. Messages with the same key (per environment, source and channel) form one
    /// group. Use one key per customer request ("requests/<id>"), a shared key only for repeats of
    /// the same problem.
    public var groupKey: String?
    public var eventType: EventType?
    /// When it happened at the source (informational).
    public var occurredAt: Date?
    /// An https link shown as "Open link" (no credentials, ≤ 2048 bytes).
    public var url: String?
    /// An https image the server fetches after ingestion (no credentials or fragment).
    public var imageURL: String?
    /// Up to 3 buttons, in display order (the first is the primary). Empty: none.
    public var actions: [Action]
    /// ≤ 16 keys matching `[A-Za-z0-9_.-]{1,64}`.
    public var metadata: [String: MetadataValue]
    /// Push lifetime, 60–86400 seconds (default 3600).
    public var ttlSeconds: Int?
    /// Monotonic counter per source stream (0 … 2^53-1) for problem/recovery ordering. Needs `groupKey`.
    public var sourceSequence: Int64?

    public init(
        _ message: String,
        title: String? = nil,
        severity: Severity? = nil,
        priority: Priority? = nil,
        category: Category? = nil,
        source: String? = nil,
        environment: String? = nil,
        channel: String? = nil,
        groupKey: String? = nil,
        eventType: EventType? = nil,
        occurredAt: Date? = nil,
        url: String? = nil,
        imageURL: String? = nil,
        actions: [Action] = [],
        metadata: [String: MetadataValue] = [:],
        ttlSeconds: Int? = nil,
        sourceSequence: Int64? = nil
    ) {
        self.message = message
        self.title = title
        self.severity = severity
        self.priority = priority
        self.category = category
        self.source = source
        self.environment = environment
        self.channel = channel
        self.groupKey = groupKey
        self.eventType = eventType
        self.occurredAt = occurredAt
        self.url = url
        self.imageURL = imageURL
        self.actions = actions
        self.metadata = metadata
        self.ttlSeconds = ttlSeconds
        self.sourceSequence = sourceSequence
    }
}

/// Values applied when a message leaves these fields nil or empty.
public struct Defaults: Sendable, Equatable {
    public var source: String?
    public var environment: String?
    public var channel: String?

    public init(source: String? = nil, environment: String? = nil, channel: String? = nil) {
        self.source = source
        self.environment = environment
        self.channel = channel
    }
}

/// The 202 answer: the message is durably stored (which does not mean a push was delivered).
public struct Accepted: Sendable, Equatable {
    /// Message id (`msg_…`); the original id when `duplicate` is true.
    public let id: String
    /// This idempotency key was already accepted with the same payload in the last 24 hours.
    public let duplicate: Bool
    /// When the server accepted it (the first time, for a duplicate).
    public let receivedAt: Date

    public init(id: String, duplicate: Bool, receivedAt: Date) {
        self.id = id
        self.duplicate = duplicate
        self.receivedAt = receivedAt
    }
}

/// Exponential backoff with full jitter: attempt n waits random(0, min(max, base·2ⁿ)), or the
/// server's Retry-After when longer.
public struct Backoff: Sendable, Equatable {
    public var base: Duration
    public var max: Duration

    public init(base: Duration = .milliseconds(500), max: Duration = .seconds(8)) {
        self.base = base
        self.max = max
    }
}
