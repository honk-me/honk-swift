import Foundation
import Testing

@testable import HonkMe

/// Runs against a real Honk server when HONK_URL and HONK_KEY are set (see ../../README.md,
/// "Integration tests"); skipped otherwise.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["HONK_URL"] != nil && ProcessInfo.processInfo.environment["HONK_KEY"] != nil))
struct IntegrationTests {
    let run = "swift-\(UUIDv7.make())"

    func client(key: String? = nil, validate: Bool = true) throws -> Honk {
        let env = ProcessInfo.processInfo.environment
        return try Honk(url: env["HONK_URL"]!, key: key ?? env["HONK_KEY"]!, defaults: Defaults(source: "sdk-swift-it", environment: "test"), validate: validate)
    }

    @Test func minimalMessageIsAccepted() async throws {
        let accepted = try await client().send(Message("minimal \(run)"))
        #expect(accepted.id.hasPrefix("msg_") && !accepted.duplicate)
    }

    @Test func everyFieldAndAReplayIsADuplicate() async throws {
        let honk = try client()
        let message = Message(
            "Ana (Acme) asked for a quote:\nonline shop, 40 products", title: "Customer request \(run)", severity: .light,
            priority: .high, category: .customers, source: "sdk-swift-it", environment: "test", channel: "requests",
            groupKey: "requests/\(run)", eventType: .event, occurredAt: Date(), url: "https://example.com/admin/requests/4812",
            imageURL: "https://example.com/images/quote.png", metadata: ["request_id": "4812", "amount": 1250.5, "vip": true],
            ttlSeconds: 600, sourceSequence: 1)
        let key = "it-\(UUIDv7.make())"
        let first = try await honk.send(message, idempotencyKey: key)
        let again = try await honk.send(message, idempotencyKey: key)
        #expect(!first.duplicate && again.duplicate && again.id == first.id)
    }

    @Test func actionsAreAcceptedAndPartOfTheIdempotencyPayload() async throws {
        let honk = try client()
        let key = "it-\(UUIDv7.make())"
        var message = Message(
            "Emily Carter asked for a quote \(run)", title: "New quote request", groupKey: "requests/\(run)",
            actions: [Action(title: "Reply", url: "mailto:emily@example.com?subject=Your%20quote"), Action(title: "Call", url: "tel:+15550134")])
        let first = try await honk.send(message, idempotencyKey: key)
        let again = try await honk.send(message, idempotencyKey: key)
        #expect(!first.duplicate && again.duplicate && again.id == first.id)
        message.actions.removeLast()
        do {
            try await honk.send(message, idempotencyKey: key)
            Issue.record("expected a conflict")
        } catch HonkError.conflict(let f) {
            #expect(f.status == 409 && f.code == "idempotency_conflict")
        }
    }

    @Test func sameKeyDifferentPayloadIsAConflict() async throws {
        let honk = try client()
        let key = "it-\(UUIDv7.make())"
        try await honk.light("first", "payload A \(run)", idempotencyKey: key)
        do {
            try await honk.light("first", "payload B \(run)", idempotencyKey: key)
            Issue.record("expected a conflict")
        } catch HonkError.conflict(let f) {
            #expect(f.status == 409 && f.code == "idempotency_conflict" && f.idempotencyKey == key)
        }
    }

    @Test func problemThenRecovery() async throws {
        let honk = try client()
        let group = "it/swift/\(run)"
        let p = try await honk.problem(groupKey: group, "Backup failed", "pg_dump exited with 1") { $0.sourceSequence = 1 }
        let r = try await honk.recovery(groupKey: group, "Backup OK", "pg_dump finished") { $0.sourceSequence = 2 }
        #expect(p.id != r.id)
    }

    @Test func hornAliasAndCanonicalSeverityAreTheSameEvent() async throws {
        let honk = try client()
        let key = "it-\(UUIDv7.make())"
        let first = try await honk.loud("Disk 91%", "/var on app-01 \(run)", idempotencyKey: key)
        let again = try await honk.send(Message("/var on app-01 \(run)", title: "Disk 91%", severity: Severity(parsing: "WARNING")), idempotencyKey: key)
        #expect(again.duplicate && again.id == first.id)
    }

    @Test func wrongKeyIsAnAuthError() async throws {
        do {
            try await client(key: "honk_000000000000_00000000000000000000000000000000").send(Message("x"))
            Issue.record("expected an auth error")
        } catch HonkError.auth(let f) {
            #expect(f.status == 401 && f.code == "invalid_key")
        }
    }

    @Test func urgentWithoutAllowUrgent() async throws {
        do {
            let accepted = try await client().send(Message("urgent \(run)", priority: .urgent))
            #expect(accepted.id.hasPrefix("msg_"))  // the key allows urgent
        } catch HonkError.auth(let f) {
            #expect(f.status == 403 && f.code == "priority_not_allowed")
        }
    }

    @Test func serverSideValidationMapsFields() async throws {
        do {
            try await client(validate: false).send(Message("x", ttlSeconds: 5))
            Issue.record("expected a validation error")
        } catch HonkError.validation(let f) {
            #expect(!f.isLocal && f.status == 422 && f.fields.map { "\($0.field):\($0.code)" } == ["ttl_seconds:out_of_range"])
        }
    }

    @Test func serverSideActionValidationMapsFields() async throws {
        do {
            try await client(validate: false).send(Message("x", actions: [Action(title: "Call", url: "tel:+15550134"), Action(title: "Open", url: "javascript:alert(1)")]))
            Issue.record("expected a validation error")
        } catch HonkError.validation(let f) {
            #expect(!f.isLocal && f.status == 422 && f.fields.map { "\($0.field):\($0.code)" } == ["actions[1].url:invalid_format"])
        }
    }
}
