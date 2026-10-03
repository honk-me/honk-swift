import Foundation
import Testing

@testable import HonkMe

func isUUIDv7(_ s: String) -> Bool {
    s.wholeMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/) != nil
}

@Suite(.serialized)
struct ClientTests {
    @Test func serialisesEveryFieldWithTheOpenAPINames() async throws {
        MockURLProtocol.script([.accepted()])
        let honk = try mockClient()
        let accepted = try await honk.send(
            Message(
                "Billing API could not connect to Redis after 3 attempts.",
                title: "Redis connection failed", severity: .long, priority: .high, category: .infrastructure,
                source: "billing-api", environment: "production", channel: "infrastructure",
                groupKey: "billing/redis/connectivity", eventType: .problem,
                occurredAt: ISO8601DateFormatter().date(from: "2026-10-01T21:10:00Z"),
                url: "https://example.com/incidents/redis", imageURL: "https://cdn.example.com/a.jpg?w=1&h=2",
                metadata: ["host": "app-01", "attempts": 3, "retried": true, "ratio": 0.5],
                ttlSeconds: 3600, sourceSequence: 42
            ))
        #expect(accepted.id == "msg_01k6h3w4z5x6y7z8a9b0c1d2e3")
        #expect(!accepted.duplicate)
        #expect(Wire.formatTimestamp(accepted.receivedAt) == "2026-10-02T21:10:00.123Z")

        let r = try #require(MockURLProtocol.requests.first)
        #expect(r.url.absoluteString == "https://honk.test/v1/messages")
        #expect(r.header("Authorization") == "Bearer \(testKey)")
        #expect(r.header("Content-Type") == "application/json")
        #expect(r.header("User-Agent") == "honk-me-swift/\(Honk.version)")
        #expect(isUUIDv7(r.header("Idempotency-Key") ?? ""))
        let json = r.json
        #expect(json["title"] as? String == "Redis connection failed")
        #expect(json["severity"] as? String == "error")
        #expect(json["priority"] as? String == "high")
        #expect(json["category"] as? String == "infrastructure")
        #expect(json["group_key"] as? String == "billing/redis/connectivity")
        #expect(json["event_type"] as? String == "problem")
        #expect(json["occurred_at"] as? String == "2026-10-01T21:10:00.000Z")
        #expect(json["image_url"] as? String == "https://cdn.example.com/a.jpg?w=1&h=2")
        #expect(json["ttl_seconds"] as? Int == 3600)
        #expect(json["source_sequence"] as? Int == 42)
        let md = try #require(json["metadata"] as? [String: Any])
        #expect(md["host"] as? String == "app-01" && md["attempts"] as? Int == 3 && md["retried"] as? Bool == true)
        #expect(Set(json.keys) == ["title", "message", "severity", "priority", "category", "source", "environment", "channel", "group_key", "event_type", "occurred_at", "url", "image_url", "metadata", "ttl_seconds", "source_sequence"])
        #expect(!String(decoding: r.body, as: UTF8.self).contains(#"\/"#))
    }

    @Test func minimalMessageAndDefaults() async throws {
        MockURLProtocol.script([.accepted()])
        let honk = try mockClient(defaults: Defaults(source: "cron", environment: "production", channel: ""))
        try await honk.send(Message("a"))
        try await honk.send(Message("b", source: "laravel", channel: "requests"))
        let r = MockURLProtocol.requests
        #expect(r[0].json as NSDictionary == ["message": "a", "source": "cron", "environment": "production"])
        #expect(r[1].json as NSDictionary == ["message": "b", "source": "laravel", "environment": "production", "channel": "requests"])
    }

    @Test func helpersAndTheHonkScale() async throws {
        MockURLProtocol.script([.accepted()])
        let honk = try mockClient()
        try await honk.light("a", "m")
        try await honk.beep("b", "m")
        try await honk.loud("c", "m") { $0.groupKey = "disk/var" }
        try await honk.long("d", "m")
        try await honk.blast("e", "m") { $0.severity = .light }
        try await honk.problem(groupKey: "db/backup", "Backup failed", "exit 1", idempotencyKey: "p-1")
        try await honk.recovery(groupKey: "db/backup", "Backup OK", "exit 0")
        try await honk.problem(groupKey: "q", "Queue", "failing") { $0.severity = .blast }
        try await honk.warning(nil, "synonym")
        let r = MockURLProtocol.requests
        #expect(r.map { $0.json["severity"] as? String } == ["info", "success", "warning", "error", "critical", "error", "success", "critical", "warning"])
        #expect(r[2].json["group_key"] as? String == "disk/var")
        #expect(r[5].json["event_type"] as? String == "problem" && r[5].header("Idempotency-Key") == "p-1")
        #expect(r[6].json["event_type"] as? String == "recovery")
        #expect(r[8].json["title"] == nil)
        #expect(Severity.loud == .warning && Severity.blast == .critical && Severity(parsing: " LOUD ") == .warning && Severity(parsing: "fatal") == nil)
        #expect(Severity.warning.horn == "loud")
    }

    @Test func retriesReuseTheIdempotencyKeyAndBody() async throws {
        MockURLProtocol.script([.error(503, "unavailable", retryAfter: "0"), .error(500, "internal"), .fail(.networkConnectionLost), .accepted()])
        let accepted = try await mockClient().send(Message("x"))
        #expect(accepted.id.hasPrefix("msg_"))
        let r = MockURLProtocol.requests
        #expect(r.count == 4)
        #expect(Set(r.map { $0.header("Idempotency-Key") }).count == 1)
        #expect(Set(r.map(\.body)).count == 1)
    }

    @Test func retriesATimedOutAttempt() async throws {
        MockURLProtocol.script([.respond(status: 202, body: "{}", delay: .milliseconds(600)), .accepted()])
        try await mockClient(timeout: .milliseconds(150)).send(Message("x"), idempotencyKey: "k-1")
        let r = MockURLProtocol.requests
        #expect(r.count == 2 && r.allSatisfy { $0.header("Idempotency-Key") == "k-1" })
    }

    @Test func honoursRetryAfter() async throws {
        MockURLProtocol.script([.error(429, "rate_limited", retryAfter: "1"), .accepted()])
        let start = ContinuousClock.now
        try await mockClient().send(Message("x"))
        #expect(ContinuousClock.now - start >= .seconds(1))
    }

    @Test func retryAfterBeyondTheDeadlineFailsFast() async throws {
        MockURLProtocol.script([.error(429, "quota_exceeded", retryAfter: "7200", extra: #","limit":"messages_per_day""#)])
        let start = ContinuousClock.now
        await #expect {
            try await mockClient().send(Message("x"), idempotencyKey: "q-1")
        } throws: { error in
            guard case HonkError.quota(let f) = error else { return false }
            return f.code == "quota_exceeded" && f.status == 429 && f.retryAfter == .seconds(7200) && f.attempts == 1
                && f.idempotencyKey == "q-1" && (error as! HonkError).isRetryable
        }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func givesUpAfterRetries() async throws {
        MockURLProtocol.script([.error(503, "unavailable", retryAfter: "0")])
        await #expect {
            try await mockClient(retries: 2).send(Message("x"))
        } throws: { error in
            guard case HonkError.server(let f) = error else { return false }
            return f.attempts == 3 && f.code == "unavailable" && f.requestID == "req_test"
        }
        #expect(MockURLProtocol.requests.count == 3)
    }

    @Test func stopsAtTheDeadline() async throws {
        MockURLProtocol.script([.error(503, "unavailable", retryAfter: "1")])
        let start = ContinuousClock.now
        await #expect(throws: HonkError.self) {
            try await mockClient(retries: 10, deadline: .milliseconds(1500)).send(Message("x"))
        }
        #expect(ContinuousClock.now - start < .milliseconds(1600))
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test func timeoutError() async throws {
        MockURLProtocol.script([.respond(status: 202, body: "{}", delay: .milliseconds(500))])
        await #expect {
            try await mockClient(timeout: .milliseconds(50), retries: 1).send(Message("x"))
        } throws: { error in
            guard case HonkError.timeout(let f) = error else { return false }
            return f.attempts == 2 && f.code == "timeout" && (error as! HonkError).isRetryable
        }
    }

    @Test func networkError() async throws {
        MockURLProtocol.script([.fail(.cannotConnectToHost)])
        await #expect {
            try await mockClient(retries: 1).send(Message("x"))
        } throws: { error in
            guard case HonkError.network(let f) = error else { return false }
            return f.code == "network_error" && f.attempts == 2 && isUUIDv7(f.idempotencyKey ?? "")
        }
    }

    @Test func cancellationThrowsCancellationError() async throws {
        MockURLProtocol.script([.respond(status: 202, body: "{}", delay: .seconds(2))])
        let honk = try mockClient()
        let task = Task { try await honk.send(Message("x")) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [
        (Step.error(422, "validation_failed", extra: #","fields":[{"field":"severity","code":"invalid_enum","message":"must be one of"}]"#), "validation", "validation_failed"),
        (Step.error(413, "payload_too_large"), "validation", "payload_too_large"),
        (Step.error(401, "invalid_key"), "auth", "invalid_key"),
        (Step.error(403, "priority_not_allowed"), "auth", "priority_not_allowed"),
        (Step.error(409, "idempotency_conflict"), "conflict", "idempotency_conflict"),
        (Step.error(404, "not_found"), "http", "not_found"),
    ])
    func errorMappingIsNeverRetried(step: Step, kind: String, code: String) async throws {
        MockURLProtocol.script([step])
        do {
            try await mockClient().send(Message("x"))
            Issue.record("expected an error")
        } catch let error as HonkError {
            let actual: String =
                switch error {
                case .validation: "validation"
                case .auth: "auth"
                case .conflict: "conflict"
                case .http: "http"
                default: "other"
                }
            #expect(actual == kind)
            #expect(error.failure?.code == code && error.failure?.requestID == "req_test" && error.failure?.attempts == 1)
            #expect(!error.isRetryable && error.failure?.isLocal == false)
        }
        #expect(MockURLProtocol.requests.count == 1)
    }

    @Test func validationErrorsExposeFields() async throws {
        MockURLProtocol.script([.error(422, "validation_failed", extra: #","fields":[{"field":"image_url","code":"invalid_format","message":"must be https"}]"#)])
        do {
            try await mockClient().send(Message("x"))
            Issue.record("expected an error")
        } catch let error as HonkError {
            #expect(error.failure?.fields == [FieldError(field: "image_url", code: "invalid_format", message: "must be https")])
            #expect(error.description.contains("image_url must be https"))
        }
    }

    @Test func proxyHTMLErrorIsRetriedThenReported() async throws {
        MockURLProtocol.script([.respond(status: 502, body: "<html>Bad Gateway</html>")])
        await #expect {
            try await mockClient(retries: 1).send(Message("x"))
        } throws: { error in
            guard case HonkError.server(let f) = error else { return false }
            return f.status == 502 && f.code == nil
        }
        #expect(MockURLProtocol.requests.count == 2)
    }

    @Test func duplicateAndExplicitKey() async throws {
        MockURLProtocol.script([.accepted(duplicate: true)])
        let accepted = try await mockClient().send(Message("x"), idempotencyKey: "deploy-4812")
        #expect(accepted.duplicate)
        #expect(MockURLProtocol.requests[0].header("Idempotency-Key") == "deploy-4812")
    }

    @Test func validateFalseLeavesValueChecksToTheServer() async throws {
        MockURLProtocol.script([.error(422, "validation_failed")])
        await #expect(throws: HonkError.self) {
            try await mockClient(validate: false).send(Message("x", ttlSeconds: 5))
        }
        #expect(MockURLProtocol.requests[0].json["ttl_seconds"] as? Int == 5)
    }
}

@Suite struct ConfigurationTests {
    @Test func rejectsMissingOrMalformedURLAndKey() {
        let cases: [(String, String, String)] = [
            ("", testKey, "HONK_URL"), ("honk.example.com", testKey, "https://"),
            ("https://h", "", "HONK_KEY"), ("https://h", "hka_mobile", "honk_"),
        ]
        for (url, key, needle) in cases {
            #expect {
                _ = try Honk(url: url, key: key)
            } throws: { error in
                guard case HonkError.invalidConfiguration(let message) = error else { return false }
                return message.contains(needle)
            }
        }
    }

    @Test func normalisesTheURL() throws {
        #expect(try Honk(url: "https://honk.example.com/v1/messages/", key: testKey).url.absoluteString == "https://honk.example.com")
    }

    @Test func fromEnvironment() throws {
        let honk = try Honk.fromEnvironment(["HONK_URL": "https://honk.example.com", "HONK_KEY": testKey, "HONK_SOURCE": "cron"])
        #expect(honk.defaults == Defaults(source: "cron"))
    }

    @Test func uuidv7IsVersion7AndTimeOrdered() throws {
        let a = UUIDv7.make(at: Date(timeIntervalSince1970: 1_700_000_000))
        let b = UUIDv7.make(at: Date(timeIntervalSince1970: 1_700_000_000.001))
        #expect(isUUIDv7(a))
        #expect(a < b)
        #expect(a.prefix(13).replacingOccurrences(of: "-", with: "") == "018bcfe56800")
    }

    @Test func parsesRetryAfter() {
        let now = ISO8601DateFormatter().date(from: "2026-10-02T10:00:00Z")!
        #expect(Honk.parseRetryAfter("3") == .seconds(3))
        #expect(Honk.parseRetryAfter(" 120 ") == .seconds(120))
        #expect(Honk.parseRetryAfter(nil) == nil)
        #expect(Honk.parseRetryAfter("soon") == nil)
        #expect(Honk.parseRetryAfter("Fri, 02 Oct 2026 10:00:30 GMT", now: now) == .seconds(30))
        #expect(Honk.parseRetryAfter("Fri, 02 Oct 2026 09:00:00 GMT", now: now) == .seconds(0))
    }
}
