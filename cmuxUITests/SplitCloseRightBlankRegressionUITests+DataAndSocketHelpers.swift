import XCTest
import Foundation
import CoreGraphics
import ImageIO
import Darwin


// MARK: - Data & socket helpers
extension SplitCloseRightBlankRegressionUITests {
    private func waitForData(keys: [String], timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            return keys.allSatisfy { data[$0] != nil }
        }
    }

    func waitForAnyData(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.loadData() != nil
        }
    }

    func waitForSettledData(timeout: TimeInterval) -> [String: String]? {
        var last: [String: String]?

        _ = waitForCondition(timeout: timeout) {
            guard let data = self.loadData() else { return false }
            last = data

            if let setupError = data["setupError"], !setupError.isEmpty {
                return true
            }

            let finalPaneCount = Int(data["finalPaneCount"] ?? "") ?? -1
            let missingSelected = Int(data["missingSelectedTabCount"] ?? "") ?? -1
            let missingMapping = Int(data["missingPanelMappingCount"] ?? "") ?? -1
            let emptyPanels = Int(data["emptyPanelAppearCount"] ?? "") ?? -1
            let selectedTerminalCount = Int(data["selectedTerminalCount"] ?? "") ?? -1
            let selectedTerminalAttached = Int(data["selectedTerminalAttachedCount"] ?? "") ?? -1
            let selectedTerminalZeroSize = Int(data["selectedTerminalZeroSizeCount"] ?? "") ?? -1
            let selectedTerminalSurfaceNil = Int(data["selectedTerminalSurfaceNilCount"] ?? "") ?? -1

            let settled =
                finalPaneCount == 2 &&
                missingSelected == 0 &&
                missingMapping == 0 &&
                emptyPanels == 0 &&
                selectedTerminalCount == 2 &&
                selectedTerminalAttached == 2 &&
                selectedTerminalZeroSize == 0 &&
                selectedTerminalSurfaceNil == 0
            if settled {
                return true
            }

            let attempt = Int(data["finalAttempt"] ?? "") ?? -1
            return attempt >= 20
        }
        return last
    }

    func loadData() -> [String: String]? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: String]
    }

    private func loadDiagnostics() -> [String: String]? {
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: String]
    }

    // MARK: - Automation Socket Client (UI Tests)

    private func waitForSocketPong(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.socketCommand("ping") == "PONG"
        }
    }

    func waitForVisualDone(timeout: TimeInterval) -> Bool {
        waitForCondition(timeout: timeout) {
            self.loadData()?["visualDone"] == "1"
        }
    }

    private func socketCommand(_ cmd: String) -> String? {
        if socketClient == nil {
            socketClient = ControlSocketClient(path: socketPath)
        }
        if let v = socketClient?.sendLine(cmd) {
            return v
        }
        // Fallback: use `nc -U` (more tolerant of Darwin sockaddr_un quirks across OS versions).
        return socketCommandViaNetcat(cmd)
    }

    private func socketCommandViaNetcat(_ cmd: String) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nc)
        proc.arguments = ["-U", socketPath, "-w", "2"]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        if let data = (cmd + "\n").data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        inPipe.fileHandleForWriting.closeFile()

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        if let first = outStr.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
