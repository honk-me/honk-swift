import Foundation

/// UUIDv7 (RFC 9562): 48-bit Unix milliseconds, then random bits. Used for automatic
/// idempotency keys; store one with your job to retry the same event across restarts.
public enum UUIDv7 {
    public static func make(at date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<16 { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        let ms = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        bytes[6] = (bytes[6] & 0x0F) | 0x70  // version 7
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // variant 10
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }
}
