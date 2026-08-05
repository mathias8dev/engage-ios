import Foundation
#if canImport(OSLog)
import OSLog
#endif

public enum EngageLogLevel: Int, Comparable, Sendable {
    case verbose = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case none = 5

    public static func < (lhs: EngageLogLevel, rhs: EngageLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Shared native logger used by every Engage module.
///
/// Messages are deliberately limited to technical metadata. Credentials, tokens,
/// binding codes, payload values and user attributes must never be passed here.
public enum EngageLogger {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var level: EngageLogLevel = .info
    }
    private static let state = State()
    #if canImport(OSLog)
    private static let native = Logger(subsystem: "io.engage.sdk", category: "Engage")
    #endif

    public static var level: EngageLogLevel {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.level
    }

    public static func configure(level: EngageLogLevel) {
        state.lock.lock(); state.level = level; state.lock.unlock()
        info("Core", "logger configured level=\(level)")
    }

    public static func verbose(_ component: String, _ message: String) {
        emit(.verbose, component, message, error: nil)
    }

    public static func debug(_ component: String, _ message: String) {
        emit(.debug, component, message, error: nil)
    }

    public static func info(_ component: String, _ message: String) {
        emit(.info, component, message, error: nil)
    }

    public static func warning(_ component: String, _ message: String, error: Error? = nil) {
        emit(.warning, component, message, error: error)
    }

    public static func error(_ component: String, _ message: String, error: Error? = nil) {
        emit(.error, component, message, error: error)
    }

    private static func emit(_ eventLevel: EngageLogLevel, _ component: String, _ message: String, error: Error?) {
        let threshold = level
        guard threshold != .none, eventLevel >= threshold else { return }
        var line = "[\(eventLevel)] [\(component)] \(message)"
        if let error { line += " errorType=\(String(reflecting: type(of: error)))" }
        #if canImport(OSLog)
        switch eventLevel {
        case .verbose: native.trace("\(line, privacy: .public)")
        case .debug: native.debug("\(line, privacy: .public)")
        case .info: native.info("\(line, privacy: .public)")
        case .warning: native.warning("\(line, privacy: .public)")
        case .error: native.error("\(line, privacy: .public)")
        case .none: break
        }
        #else
        print("Engage \(line)")
        #endif
    }
}
