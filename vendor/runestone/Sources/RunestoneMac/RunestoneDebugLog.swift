import Foundation

public enum RunestoneDebugLog {
    private static let logFileEnvironmentKey = "RUNESTONE_DEMO_DEBUG_LOG_FILE"
    private static let fileQueue = DispatchQueue(label: "RunestoneDebugLog.file", qos: .utility)
    private static let configuredLogFilePath: String? = {
        guard let path = ProcessInfo.processInfo.environment[logFileEnvironmentKey],
              !path.isEmpty else {
            return nil
        }
        return path
    }()
    private static var fileHandle: FileHandle?

    public static func write(_ message: @autoclosure () -> String) {
        let line = message() + "\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        fileQueue.async {
            FileHandle.standardError.write(data)
            guard let handle = openFileHandleIfNeeded() else {
                return
            }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    public static func flush() {
        fileQueue.sync {
            fileHandle?.synchronizeFile()
        }
    }

    private static func openFileHandleIfNeeded() -> FileHandle? {
        if let fileHandle {
            return fileHandle
        }
        guard let configuredLogFilePath else {
            return nil
        }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: configuredLogFilePath) {
            fileManager.createFile(atPath: configuredLogFilePath, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: configuredLogFilePath) else {
            return nil
        }
        fileHandle = handle
        return handle
    }
}
