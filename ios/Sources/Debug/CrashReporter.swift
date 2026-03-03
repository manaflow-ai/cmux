import Foundation
import Darwin

enum CrashReporter {
    private static var signalFileDescriptor: Int32 = -1

    static func install() {
        #if DEBUG
        openSignalLogFile()
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "unknown"
            let stack = exception.callStackSymbols.joined(separator: "\n")
            DebugLog.addSync("Uncaught exception: \(name) reason: \(reason)\n\(stack)")
        }
        registerSignalHandlers()
        #endif
    }

    #if DEBUG
    private static func openSignalLogFile() {
        guard signalFileDescriptor == -1 else { return }
        do {
            guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                return
            }
            let directoryURL = baseURL.appendingPathComponent("cmux", isDirectory: true)
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            let fileURL = directoryURL.appendingPathComponent("debug.log")
            signalFileDescriptor = open(fileURL.path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        } catch {
            print("CrashReporter error: \(error)")
        }
    }

    private static func registerSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { signal in
            CrashReporter.writeSignal(signal)
            Darwin.signal(signal, SIG_DFL)
            Darwin.raise(signal)
        }
        var action = sigaction()
        action.__sigaction_u = __sigaction_u(__sa_handler: handler)
        action.sa_flags = 0
        sigemptyset(&action.sa_mask)
        _ = sigaction(SIGABRT, &action, nil)
        _ = sigaction(SIGSEGV, &action, nil)
        _ = sigaction(SIGBUS, &action, nil)
        _ = sigaction(SIGILL, &action, nil)
        _ = sigaction(SIGTRAP, &action, nil)
    }

    private static func writeSignal(_ signal: Int32) {
        let message = "Caught signal: \(signal)\n"
        message.withCString { pointer in
            let length = strlen(pointer)
            if signalFileDescriptor >= 0 {
                _ = write(signalFileDescriptor, pointer, length)
            } else {
                _ = write(STDERR_FILENO, pointer, length)
            }
        }
    }
    #endif
}
