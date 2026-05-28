import Foundation
public import Logging

public enum CmuxLog {
    /// Subsystem logger for the protocol/transport layer. The app target
    /// configures the `LoggingSystem.bootstrap` once on launch (e.g. to
    /// `OSLogHandler` for unified-log forwarding); CmuxKit only uses
    /// `Logger` instances.
    public static func make(_ label: String) -> Logger {
        Logger(label: "com.cmuxterm.remote.\(label)")
    }
}
