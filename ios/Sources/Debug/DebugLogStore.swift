import Foundation

enum DebugLog {
    private static let queue = DispatchQueue(label: "dev.cmux.debuglog", qos: .utility)
    private static let queueKey = DispatchSpecificKey<Bool>()
    private static let maxBytes = 200_000
    private static let directoryName = "cmux"
    private static let fileName = "debug.log"
    private static var lastMessageByKey: [String: String] = [:]
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let queueSpecificToken: Void = {
        queue.setSpecific(key: queueKey, value: true)
        return ()
    }()

    private static func fileURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directoryURL = baseURL.appendingPathComponent(directoryName, isDirectory: true)
        return directoryURL.appendingPathComponent(fileName)
    }

    static func add(_ message: String, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        _ = queueSpecificToken
        let entry = makeEntry(message: message, file: file, line: line)
        queue.async { write(entry: entry) }
        #else
        _ = message
        _ = file
        _ = line
        #endif
    }

    static func addDedup(_ key: String, _ message: String, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        _ = queueSpecificToken
        let signature = "\(message) (\(file):\(line))"
        let entry = makeEntry(message: message, file: file, line: line)
        queue.async {
            let last = lastMessageByKey[key]
            if last == signature {
                return
            }
            lastMessageByKey[key] = signature
            write(entry: entry)
        }
        #else
        _ = key
        _ = message
        _ = file
        _ = line
        #endif
    }

    static func addSync(_ message: String, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        _ = queueSpecificToken
        let entry = makeEntry(message: message, file: file, line: line)
        if DispatchQueue.getSpecific(key: queueKey) == true {
            write(entry: entry)
        } else {
            queue.sync {
                write(entry: entry)
            }
        }
        #else
        _ = message
        _ = file
        _ = line
        #endif
    }

    static func read() -> String {
        #if DEBUG
        return queue.sync {
            guard let url = fileURL() else { return "" }
            do {
                let data = try Data(contentsOf: url)
                let text = String(decoding: data, as: UTF8.self)
                return dedupeLogText(text)
            } catch {
                print("DebugLog error: \(error)")
                return ""
            }
        }
        #else
        return ""
        #endif
    }

    static func clear() {
        #if DEBUG
        queue.async {
            guard let url = fileURL() else { return }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("DebugLog error: \(error)")
            }
        }
        #endif
    }

    private static func makeEntry(message: String, file: String, line: Int) -> String {
        let timestamp = dateFormatter.string(from: Date())
        return "[\(timestamp)] \(message) (\(file):\(line))\n"
    }

    private static func dedupeLogText(_ text: String) -> String {
        var output: [String] = []
        output.reserveCapacity(128)
        var seen = Set<String>()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for lineSlice in lines {
            let line = String(lineSlice)
            if line.isEmpty {
                continue
            }
            let signature = signatureForLine(line)
            if seen.contains(signature) {
                continue
            }
            output.append(line)
            seen.insert(signature)
        }
        if output.isEmpty {
            return ""
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func signatureForLine(_ line: String) -> String {
        if let endRange = line.range(of: "] ") {
            return String(line[endRange.upperBound...])
        }
        return line
    }

    private static func write(entry: String) {
        guard let url = fileURL() else { return }
        do {
            try ensureDirectoryExists(for: url)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let data = entry.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
            try trimFileIfNeeded(url: url)
        } catch {
            print("DebugLog error: \(error)")
        }
    }

    private static func ensureDirectoryExists(for url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
        }
    }

    private static func trimFileIfNeeded(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let sizeValue = attributes[.size] as? NSNumber else { return }
        let size = sizeValue.intValue
        guard size > maxBytes else { return }
        let keepBytes = maxBytes
        let handle = try FileHandle(forReadingFrom: url)
        try handle.seek(toOffset: UInt64(max(0, size - keepBytes)))
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        try data.write(to: url, options: .atomic)
    }
}
