import Foundation
@testable import UsageCore

let now = ISODate.parse("2026-11-21T20:15:00Z")!
let gb = Locale(identifier: "en_GB")
let utc = TimeZone(identifier: "UTC")!

/// Records calls from the sources' synchronous and `@Sendable` hooks.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Hands out a different value on each call, repeating the last one.
final class Sequence<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value]

    init(_ values: [Value]) {
        self.values = values
    }

    func next() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return values.count > 1 ? values.removeFirst() : values[0]
    }
}

func reply(_ status: Int, _ body: String = "{}", retryAfter: TimeInterval? = nil) -> HTTP.Reply {
    HTTP.Reply(status: status, data: Data(body.utf8), retryAfter: retryAfter)
}
