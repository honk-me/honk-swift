import Foundation
import Testing

@testable import HonkMe

@Suite struct ValidationTests {
    static let cases: [(String, Message, String, String)] = {
        var many: [String: MetadataValue] = [:]
        for i in 0..<17 { many["k\(i)"] = .int(i) }
        let call = Action(title: "Call", url: "tel:+15550134")
        let action = { (title: String, url: String) in Message("x", actions: [Action(title: title, url: url)]) }
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
            ("four actions", Message("x", actions: [call, call, call, call]), "actions", "too_long"),
            ("blank action title", action("  ", "tel:1"), "actions[0].title", "required"),
            ("long action title", action(String(repeating: "t", count: 41), "tel:1"), "actions[0].title", "too_long"),
            ("action title line break", action("Call\nEmily", "tel:1"), "actions[0].title", "invalid_format"),
            ("action title control", action("Call\u{7}", "tel:1"), "actions[0].title", "invalid_format"),
            ("empty action url", action("Open", ""), "actions[0].url", "required"),
            ("long action url", action("Open", "https://example.com/" + String(repeating: "a", count: 2029)), "actions[0].url", "too_long"),
            ("http action", action("Open", "http://example.com"), "actions[0].url", "invalid_format"),
            ("javascript action", action("Open", "javascript:alert(1)"), "actions[0].url", "invalid_format"),
            ("app scheme action", action("Open", "shop://orders/42"), "actions[0].url", "invalid_format"),
            ("action credentials", action("Open", "https://user:pw@example.com"), "actions[0].url", "invalid_format"),
            ("action without host", action("Open", "https:///orders"), "actions[0].url", "invalid_format"),
            ("action space", action("Reply", "mailto:emily@example.com?subject=Your quote"), "actions[0].url", "invalid_format"),
            ("mailto without address", action("Reply", "mailto:?subject=Hi"), "actions[0].url", "invalid_format"),
            ("mailto undotted domain", action("Reply", "mailto:emily@localhost"), "actions[0].url", "invalid_format"),
            ("mailto two addresses", action("Reply", "mailto:emily@example.com,bob@example.com"), "actions[0].url", "invalid_format"),
            ("mailto display name", action("Reply", "mailto:Emily%20%3Cemily@example.com%3E"), "actions[0].url", "invalid_format"),
            ("mailto double dot", action("Reply", "mailto:emily..carter@example.com"), "actions[0].url", "invalid_format"),
            ("mailto cc", action("Reply", "mailto:emily@example.com?cc=boss@example.com"), "actions[0].url", "invalid_format"),
            ("mailto bad escape", action("Reply", "mailto:emily@example.com?subject=100%"), "actions[0].url", "invalid_format"),
            ("action nbsp", action("Call", "tel:+1\u{A0}5550134"), "actions[0].url", "invalid_format"),
            ("tel letters", action("Call", "tel:+1-555-CALL"), "actions[0].url", "invalid_format"),
            ("tel without digits", action("Call", "tel:+"), "actions[0].url", "invalid_format"),
            ("sms slashes", action("Text", "sms://+15550134"), "actions[0].url", "invalid_format"),
            ("sms other query", action("Text", "sms:+15550134?subject=Hi"), "actions[0].url", "invalid_format"),
            ("sms semicolon", action("Text", "sms:+15550134?body=a;b"), "actions[0].url", "invalid_format"),
            ("tel query", action("Call", "tel:+15550134?x=1"), "actions[0].url", "invalid_format"),
            ("second action", Message("x", actions: [call, Action(title: "Open", url: "ftp://example.com")]), "actions[1].url", "invalid_format"),
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

    @Test func actionErrorsAreReportedWithTheOthers() {
        #expect {
            _ = try Wire.encode(
                Message("", url: "ftp://a", actions: [Action(title: "", url: "ftp://b"), Action(title: "Call", url: "tel:1")], ttlSeconds: 5),
                defaults: Defaults(), validate: true)
        } throws: { error in
            (error as? HonkError)?.failure?.fields.map { "\($0.field):\($0.code)" }
                == ["message:required", "url:invalid_format", "actions[0].title:required", "actions[0].url:invalid_format", "ttl_seconds:out_of_range"]
        }
    }

    @Test(arguments: [
        "https://shop.example.com/admin/orders/42?tab=notes#latest", "HTTPS://example.com:8443/a",
        "mailto:emily@example.com", "MailTo:emily@example.com?subject=Your%20quote&body=Hi%20Emily",
        "mailto:first.last+quotes@example.co.uk?subject=Your+quote", "mailto:emily%40example.com", "mailto:ana@[192.0.2.1]",
        "tel:+15550134", "tel:+1-555-013.4", "tel:(555)0134", "TEL://+15550134",
        "sms:+15550134", "SMS:5550134?body=On%20my%20way", "sms:+15550134?", "https://example.com/" + String(repeating: "a", count: 2028),
    ])
    func validActionURLs(url: String) throws {
        let body = try Wire.encode(Message("x", actions: [Action(title: "Open", url: url)]), defaults: Defaults(), validate: true)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["actions"] as? [[String: String]] == [["title": "Open", "url": url]])
    }

    @Test func validActionTitles() throws {
        let actions = [
            Action(title: String(repeating: "é", count: 40), url: "tel:1"), Action(title: "  Call Emily Carter  ", url: "tel:1"),
            Action(title: "Reply ✉️", url: "mailto:a@b.co"),
        ]
        _ = try Wire.encode(Message("x", actions: actions), defaults: Defaults(), validate: true)
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
