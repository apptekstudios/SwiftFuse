import Foundation

/// A minimal lock-protected box.
///
/// `Synchronization.Mutex` needs iOS 18 / macOS 15, so this uses `NSLock`, which is
/// available everywhere Swift runs. The lock is only ever held for pointer-sized
/// reads and writes; indexing and searching happen outside it.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @inline(__always)
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
