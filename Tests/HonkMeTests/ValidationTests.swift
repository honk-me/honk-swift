import Foundation
import Testing

@testable import HonkMe

@Suite struct ValidationTests {
    static let cases: [(String, Message, String, String)] = {
        var many: [String: MetadataValue] = [:]
        for i in 0..<17 { many["k\(i)"] = .int(i) }
        var big: [String: MetadataValue] = [:]
        for i in 0..<16 { big["k\(i)"] = .string(String(repeating: "\"", count: 500)) }
        return [
            ("empty message", Message(""), "message", "required"),
            ("blank message", Message("   "), "message", "too_short"),
            ("long message", Message(String(repeating: "x", count: 8193)), "message", "too_long"),
            ("multibyte bytes", Message(String(repeating: "é", count: 4097)), "message", "too_long"),
            ("control", Message("bell\u{07}"), "message", "invalid_format"),
            ("long title", Message("x", title: String(repeating: "t", count: 161)), "title", "too_long"),
            ("title line break", Message("x", title: "two\nlines"), "title", "invalid_format"),
            ("blank title", Message("x", title: "  "), "title", "too_short"),
            ("environment", Message("x", environment: String(repeating: "e", count: 33)), "environment", "too_long"),
            ("group key", Message("x", groupKey: String(repeating: "g", count: 129)), "group_key", "too_long"),
            ("recovery", Message("x", eventType: .recovery), "group_key", "requires_group_key"),
            ("sequence", Message("x", sourceSequence: 3), "source_sequence", "requires_group_key"),
            ("negative sequence", Message("x", groupKey: "g", sourceSequence: -1), "source_sequence", "out_of_range"),
            ("huge sequence", Message("x", groupKey: "g", sourceSequence: 1 << 53), "source_sequence", "out_of_range"),
            ("http url", Message("x", url: "http://example.com"), "url", "invalid_format"),
            ("credentials", Message("x", url: "https://user:pw@example.com"), "url", "invalid_format"),
            ("long url", Message("x", url: "https://example.com/" + String(repeating: "a", count: 2048)), "url", "invalid_format"),
            ("image fragment", Message("x", imageURL: "https://cdn.example.com/a.jpg#x"), "image_url", "invalid_format"),
            ("image port", Message("x", imageURL: "https://cdn.example.com:99999/a.jpg"), "image_url", "invalid_format"),
            ("metadata key", Message("x", metadata: ["bad key": 1]), "metadata.bad key", "invalid_format"),
            ("metadata string", Message("x", metadata: ["v": .string(String(repeating: "v", count: 513))]), "metadata.v", "invalid_format"),
            ("metadata nan", Message("x", metadata: ["n": .double(.nan)]), "metadata.n", "invalid_format"),
            ("metadata keys", Message("x", metadata: many), "metadata", "too_long"),
            ("ttl low", Message("x", ttlSeconds: 59), "ttl_seconds", "out_of_range"),
            ("ttl high", Message("x", ttlSeconds: 86401), "ttl_seconds", "out_of_range"),
            ("body size", Message(String(repeating: "x", count: 8000), metadata: big), "body", "too_long"),
        ]
    }()

    @Test(arguments: cases)
    func rejectsLocally(name: String, message: Message, field: String, code: String) {
        #expect {
            _ = try Wire.encode(message, defaults: Defaults(), validate: true)
        } throws: { error in
            guard case HonkError.validation(let f) = error else { return false }
            return f.isLocal && f.attempts == 0 && f.fields.contains { $0.field == field && $0.code == code }
        }
    }

    @Test func reportsEveryErrorAtOnce() {
        #expect {
            _ = try Wire.encode(Message("", url: "ftp://a"), defaults: Defaults(), validate: true)
        } throws: { error in
            (error as? HonkError)?.failure?.fields.map(\.field) == ["message", "url"]
        }
    }

    @Test func validEdgeCases() throws {
        let body = try Wire.encode(
            Message(
                "line1\nline2\ttab\r\n", title: String(repeating: "t", count: 160), groupKey: "g",
                url: "https://[::1]:8443/path?q=1#frag", imageURL: "HTTPS://cdn.example.com/a.jpg?size=2",
                metadata: ["a.b-c_d": "v", "n": 1.5, "b": false], ttlSeconds: 60, sourceSequence: (1 << 53) - 1),
            defaults: Defaults(), validate: true)
        #expect(String(decoding: body, as: UTF8.self).contains(#""source_sequence":9007199254740991"#))
    }

    @Test func invalidIdempotencyKeys() async throws {
        let honk = try Honk(url: "https://honk.example.com", key: testKey)
        for key in ["", "has space", String(repeating: "x", count: 129), "ünicode"] {
            await #expect {
                try await honk.send(Message("x"), idempotencyKey: key)
            } throws: { error in
                (error as? HonkError)?.failure?.fields.first?.field == "Idempotency-Key"
            }
        }
    }
}
