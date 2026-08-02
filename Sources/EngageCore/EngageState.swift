import Foundation

/// A current value plus a hot, multicast async sequence. Every subscriber receives the latest value first.
public final class EngageState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init(_ value: Value) { current = value }

    public var value: Value {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public var updates: AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
            lock.lock()
            continuations[id] = continuation
            if case .terminated = continuation.yield(current) {
                continuations[id] = nil
            }
            lock.unlock()
        }
    }

    @_spi(Modules) public func set(_ value: Value) {
        lock.lock()
        current = value
        let targets = Array(continuations.values)
        lock.unlock()
        targets.forEach { $0.yield(value) }
    }

    private func remove(_ id: UUID) {
        lock.lock(); continuations[id] = nil; lock.unlock()
    }
}

public final class EngageSignalBus<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init() {}

    public var events: AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let id = UUID()
            lock.lock(); continuations[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    @_spi(Modules) public func emit(_ value: Value) {
        lock.lock(); let targets = Array(continuations.values); lock.unlock()
        targets.forEach { $0.yield(value) }
    }

    private func remove(_ id: UUID) {
        lock.lock(); continuations[id] = nil; lock.unlock()
    }
}
