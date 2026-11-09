import Foundation
import os

/// SDK logger. The level is set once from the configuration.
enum Log {
    private static let logger = Logger(subsystem: "com.herald.sdk", category: "Herald")
    private static let levelLock = OSAllocatedUnfairLock(initialState: HeraldLogLevel.warning)

    static var level: HeraldLogLevel {
        get { levelLock.withLock { $0 } }
        set { levelLock.withLock { $0 = newValue } }
    }

    static func error(_ message: @autoclosure () -> String) { write(.error, message()) }
    static func warning(_ message: @autoclosure () -> String) { write(.warning, message()) }
    static func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    static func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }

    private static func write(_ messageLevel: HeraldLogLevel, _ message: @autoclosure () -> String) {
        guard messageLevel <= level else { return }
        let text = message()
        switch messageLevel {
        case .error: logger.error("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        default: logger.debug("\(text, privacy: .public)")
        }
    }
}
