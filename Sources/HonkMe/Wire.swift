import Foundation

/// Limits from contracts/openapi.yaml (and the server's validator).
public enum Limits {
    public static let bodyBytes = 16 * 1024
    public static let messageBytes = 8192
    public static let title = 160
    public static let source = 64
    public static let environment = 32
    public static let channel = 64
    public static let groupKey = 128
    public static let urlBytes = 2048
    public static let actions = 3
    public static let actionTitle = 40
    public static let metadataKeys = 16
    public static let metadataString = 512
    public static let ttlSeconds = 60...86400
    public static let maxSourceSequence: Int64 = (1 << 53) - 1
}

/// The exact JSON of `MessageRequest` (snake_case, nil fields omitted).
struct WireMessage: Encodable {
    var title: String?
    var message: String
    var severity: String?
    var priority: String?
    var category: String?
    var source: String?
    var environment: String?
    var channel: String?
    var group_key: String?
    var event_type: String?
    var occurred_at: String?
    var url: String?
    var image_url: String?
    var actions: [Action]?
    var metadata: [String: MetadataValue]?
    var ttl_seconds: Int?
    var source_sequence: Int64?
}

enum Wire {
    /// Applies defaults, validates (unless `validate` is false) and returns the JSON body.
    static func encode(_ m: Message, defaults: Defaults, validate: Bool) throws(HonkError) -> Data {
        let nonEmpty: (String?) -> String? = { ($0?.isEmpty ?? true) ? nil : $0 }
        let wire = WireMessage(
            title: nonEmpty(m.title),
            message: m.message,
            severity: m.severity?.rawValue,
            priority: m.priority?.rawValue,
            category: m.category?.rawValue,
            source: nonEmpty(m.source) ?? nonEmpty(defaults.source),
            environment: nonEmpty(m.environment) ?? nonEmpty(defaults.environment),
            channel: nonEmpty(m.channel) ?? nonEmpty(defaults.channel),
            group_key: nonEmpty(m.groupKey),
            event_type: m.eventType?.rawValue,
            occurred_at: m.occurredAt.map(formatTimestamp),
            url: nonEmpty(m.url),
            image_url: nonEmpty(m.imageURL),
            actions: m.actions.isEmpty ? nil : m.actions,
            metadata: m.metadata.isEmpty ? nil : m.metadata,
            ttl_seconds: m.ttlSeconds,
            source_sequence: m.sourceSequence
        )
        var errors: [FieldError] = []
        if validate {
            check(wire, into: &errors)
        } else if wire.message.isEmpty {
            errors.append(FieldError(field: "message", code: "required", message: "message is required"))
        }
        var body = Data()
        if errors.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            do {
                body = try encoder.encode(wire)
            } catch {
                errors.append(FieldError(field: "body", code: "invalid_format", message: "cannot be encoded as JSON: \(error)"))
            }
            if body.count > Limits.bodyBytes {
                errors.append(FieldError(field: "body", code: "too_long", message: "the JSON body is \(body.count) bytes; Honk accepts at most 16 KiB"))
            }
        }
        if !errors.isEmpty {
            throw localValidation(errors)
        }
        return body
    }

    static func localValidation(_ fields: [FieldError]) -> HonkError {
        .validation(.init(code: "validation_failed", message: "invalid message", fields: fields, isLocal: true))
    }

    /// RFC 3339, UTC, milliseconds: 2026-10-01T21:10:00.123Z
    static func formatTimestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!))
    }

    static func validIdempotencyKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return (1...128).contains(bytes.count) && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    private static func check(_ w: WireMessage, into e: inout [FieldError]) {
        let m = w.message
        if m.isEmpty {
            e.append(.init(field: "message", code: "required", message: "message is required"))
        } else if m.utf8.count > Limits.messageBytes {
            e.append(.init(field: "message", code: "too_long", message: "must be at most \(Limits.messageBytes) bytes of UTF-8 (got \(m.utf8.count))"))
        } else if m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            e.append(.init(field: "message", code: "too_short", message: "must not be blank"))
        } else if hasControl(m, allowBreaks: true) {
            e.append(.init(field: "message", code: "invalid_format", message: "must not contain control characters other than line breaks and tabs"))
        }
        shortText(w.title, "title", Limits.title, &e)
        shortText(w.source, "source", Limits.source, &e)
        shortText(w.environment, "environment", Limits.environment, &e)
        shortText(w.channel, "channel", Limits.channel, &e)
        shortText(w.group_key, "group_key", Limits.groupKey, &e)

        if let seq = w.source_sequence, seq < 0 || seq > Limits.maxSourceSequence {
            e.append(.init(field: "source_sequence", code: "out_of_range", message: "must be between 0 and 2^53-1"))
        }
        if w.group_key == nil {
            if w.event_type == EventType.recovery.rawValue {
                e.append(.init(field: "group_key", code: "requires_group_key", message: "recovery events require group_key"))
            }
            if w.source_sequence != nil {
                e.append(.init(field: "source_sequence", code: "requires_group_key", message: "source_sequence requires group_key"))
            }
        }
        if let url = w.url, !validURL(url, image: false) {
            e.append(.init(field: "url", code: "invalid_format", message: "must be an https URL without credentials, at most 2048 bytes"))
        }
        if let url = w.image_url, !validURL(url, image: true) {
            e.append(.init(field: "image_url", code: "invalid_format", message: "must be an https URL without credentials or fragment, at most 2048 bytes"))
        }
        if let actions = w.actions {
            checkActions(actions, &e)
        }
        if let md = w.metadata {
            if md.count > Limits.metadataKeys {
                e.append(.init(field: "metadata", code: "too_long", message: "at most \(Limits.metadataKeys) keys"))
            }
            for key in md.keys.sorted() {
                let field = "metadata.\(key)"
                if !validMetadataKey(key) {
                    e.append(.init(field: field, code: "invalid_format", message: "keys must match [A-Za-z0-9_.-]{1,64}"))
                    continue
                }
                switch md[key]! {
                case .string(let s) where s.unicodeScalars.count > Limits.metadataString || hasControl(s, allowBreaks: true):
                    e.append(.init(field: field, code: "invalid_format", message: "strings must be at most \(Limits.metadataString) characters without control characters"))
                case .double(let d) where !d.isFinite:
                    e.append(.init(field: field, code: "invalid_format", message: "numbers must be finite"))
                default:
                    break
                }
            }
        }
        if let ttl = w.ttl_seconds, !Limits.ttlSeconds.contains(ttl) {
            e.append(.init(field: "ttl_seconds", code: "out_of_range", message: "must be between 60 and 86400"))
        }
    }

    private static func shortText(_ value: String?, _ field: String, _ max: Int, _ e: inout [FieldError]) {
        guard let value else { return }
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            e.append(.init(field: field, code: "too_short", message: "must not be empty"))
        } else if s.unicodeScalars.count > max {
            e.append(.init(field: field, code: "too_long", message: "must be at most \(max) characters"))
        } else if hasControl(s, allowBreaks: false) {
            e.append(.init(field: field, code: "invalid_format", message: "must not contain control characters or line breaks"))
        }
    }

    /// At most 3 (beyond that only `actions` is reported, like the server); each title 1–40
    /// characters on one line, each URL ≤ 2048 bytes with an allowed scheme.
    private static func checkActions(_ actions: [Action], _ e: inout [FieldError]) {
        if actions.count > Limits.actions {
            e.append(.init(field: "actions", code: "too_long", message: "at most \(Limits.actions) actions"))
            return
        }
        for (i, action) in actions.enumerated() {
            let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                e.append(.init(field: "actions[\(i)].title", code: "required", message: "must not be blank"))
            } else if title.unicodeScalars.count > Limits.actionTitle {
                e.append(.init(field: "actions[\(i)].title", code: "too_long", message: "must be at most \(Limits.actionTitle) characters"))
            } else if hasControl(title, allowBreaks: false) {
                e.append(.init(field: "actions[\(i)].title", code: "invalid_format", message: "must be one line without control characters"))
            }
            let url = action.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty {
                e.append(.init(field: "actions[\(i)].url", code: "required", message: "must not be blank"))
            } else if url.utf8.count > Limits.urlBytes {
                e.append(.init(field: "actions[\(i)].url", code: "too_long", message: "must be at most \(Limits.urlBytes) bytes"))
            } else if !validActionURL(url) {
                e.append(.init(field: "actions[\(i)].url", code: "invalid_format", message: "must be an https://, mailto:, tel: or sms: URL without spaces"))
            }
        }
    }

    /// The server's check of an action URL, schemes in any case: `https://` as `url`; `mailto:`
    /// with one plain address (dotted domain) and an optional `?subject=…&body=…`; `tel:` or
    /// `tel://` with a number; `sms:` with a number and an optional `?body=…`. No whitespace or
    /// control characters, ≤ 2048 bytes.
    static func validActionURL(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf8.count <= Limits.urlBytes, !hasControl(s, allowBreaks: false),
            !s.unicodeScalars.contains(where: \.properties.isWhitespace)
        else { return false }
        // The delimiters are ASCII, so working on UTF-8 bytes splits exactly like the server.
        let bytes = Array(s.utf8)
        guard let colon = bytes.firstIndex(of: UInt8(ascii: ":")) else { return false }
        let rest = bytes[(colon + 1)...]
        let (target, query) = cut(rest, at: "?")
        switch String(decoding: bytes[..<colon], as: UTF8.self).lowercased() {
        case "https": return validURL(s, image: false)
        case "mailto": return validMailAddress(target) && validActionQuery(query, allowed: ["subject", "body"])
        case "tel": return validPhoneNumber(rest.starts(with: "//".utf8) ? rest.dropFirst(2) : rest)
        case "sms": return validPhoneNumber(target) && validActionQuery(query, allowed: ["body"])
        default: return false
        }
    }

    private static func cut(_ s: ArraySlice<UInt8>, at separator: Unicode.Scalar) -> (ArraySlice<UInt8>, ArraySlice<UInt8>) {
        guard let i = s.firstIndex(of: UInt8(ascii: separator)) else { return (s, []) }
        return (s[..<i], s[(i + 1)...])
    }

    /// An optional leading `+`, then digits and the separators `-` `.` `(` `)`, with at least one digit.
    private static func validPhoneNumber(_ s: ArraySlice<UInt8>) -> Bool {
        let rest = s.first == UInt8(ascii: "+") ? s.dropFirst() : s
        let digit = { (b: UInt8) in (0x30...0x39).contains(b) }
        return rest.contains(where: digit) && rest.allSatisfy { digit($0) || "-.()".utf8.contains($0) }
    }

    /// One plain, percent-encoded address with a dotted domain, as Go's net/mail parses it:
    /// dot-atoms (or a `[…]` domain literal), no display name, quotes, commas or spaces.
    private static func validMailAddress(_ raw: ArraySlice<UInt8>) -> Bool {
        guard let bytes = percentDecoded(raw, plusIsSpace: false) else { return false }
        let address = String(decoding: bytes, as: UTF8.self)
        guard !address.isEmpty, Array(address.utf8) == bytes, !address.unicodeScalars.contains(where: { ",<>\" ".unicodeScalars.contains($0) }),
            let at = address.unicodeScalars.firstIndex(of: "@")
        else { return false }
        let local = address.unicodeScalars[..<at]
        let domain = address.unicodeScalars[address.unicodeScalars.index(after: at)...]
        let visible = { (u: Unicode.Scalar) in (0x21...0x7E).contains(u.value) || u.value >= 0x80 }
        let dotAtom = { (s: Substring.UnicodeScalarView) in
            !s.isEmpty && s.first != "." && s.last != "." && !String(s).contains("..")
                && s.allSatisfy { $0 == "." || (visible($0) && !"()<>[]:;@\\,\"".unicodeScalars.contains($0)) }
        }
        let literal = { (s: Substring.UnicodeScalarView) in
            s.count > 2 && s.first == "[" && s.last == "]"
                && s.dropFirst().dropLast().allSatisfy { visible($0) && !"[]\\".unicodeScalars.contains($0) }
        }
        return dotAtom(local) && domain.contains(".") && (dotAtom(domain) || literal(domain))
    }

    /// The query of a mailto: or sms: action: `&`-separated, valid percent-encoding, no `;`, and
    /// only the allowed keys.
    private static func validActionQuery(_ query: ArraySlice<UInt8>, allowed: Set<String>) -> Bool {
        query.split(separator: UInt8(ascii: "&")).allSatisfy { pair in
            let (key, value) = cut(pair, at: "=")
            guard !pair.contains(UInt8(ascii: ";")), let k = percentDecoded(key, plusIsSpace: true),
                percentDecoded(value, plusIsSpace: true) != nil
            else { return false }
            return allowed.contains(String(decoding: k, as: UTF8.self))
        }
    }

    /// `%XX` escapes decoded (nil when one is malformed), `+` as a space in queries.
    private static func percentDecoded(_ s: ArraySlice<UInt8>, plusIsSpace: Bool) -> [UInt8]? {
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            switch s[i] {
            case UInt8(ascii: "%"):
                guard i + 2 < s.endIndex,
                    let hi = hexValue(s[i + 1]), let lo = hexValue(s[i + 2])
                else { return nil }
                out.append(hi << 4 | lo)
                i += 3
                continue
            case UInt8(ascii: "+") where plusIsSpace:
                out.append(UInt8(ascii: " "))
            case let b:
                out.append(b)
            }
            i += 1
        }
        return out
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: b - 0x30
        case 0x41...0x46: b - 0x41 + 10
        case 0x61...0x66: b - 0x61 + 10
        default: nil
        }
    }

    /// The server's rule: Unicode control characters (C0, DEL, C1) and U+2028/U+2029.
    static func hasControl(_ s: String, allowBreaks: Bool) -> Bool {
        s.unicodeScalars.contains { u in
            if allowBreaks, u == "\n" || u == "\t" || u == "\r" { return false }
            return u.value < 0x20 || (0x7F...0x9F).contains(u.value) || u.value == 0x2028 || u.value == 0x2029
        }
    }

    private static func validMetadataKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        return (1...64).contains(bytes.count) && bytes.allSatisfy { b in
            (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == 0x5F || b == 0x2E || b == 0x2D
        }
    }

    /// Syntactic check matching the server: https, a host, no credentials, no spaces or
    /// backslashes, ≤ 2048 bytes; image URLs also no fragment and a valid port.
    static func validURL(_ raw: String, image: Bool) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf8.count <= Limits.urlBytes, !hasControl(s, allowBreaks: false),
            !s.contains(" "), !s.contains("\\"), s.lowercased().hasPrefix("https://")
        else { return false }
        if image && s.contains("#") { return false }
        let rest = s.dropFirst("https://".count)
        let authority = rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        guard !authority.isEmpty, !authority.contains("@") else { return false }
        var host = Substring(authority)
        var port: Substring = ""
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { return false }
            host = authority[...end]
            let after = authority[authority.index(after: end)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return false }
                port = after.dropFirst()
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            port = authority[authority.index(after: colon)...]
        }
        guard !host.isEmpty, host != "[]" else { return false }
        if !port.isEmpty {
            guard port.count <= 5, port.allSatisfy(\.isASCII), let n = Int(port), (1...65535).contains(n) else { return false }
        }
        return true
    }
}
