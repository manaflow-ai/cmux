import XCTest
import Foundation
import CoreGraphics


// MARK: - cmux CLI Invocation and Path Resolution
extension MultiWindowNotificationsUITests {
    private func runCmuxNotify(
        socketPath: String,
        workspaceId: String,
        surfaceId: String,
        title: String
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        runCmuxCommand(
            socketPath: socketPath,
            arguments: [
                "notify",
                "--workspace",
                workspaceId,
                "--surface",
                surfaceId,
                "--title",
                title,
                "--subtitle",
                "ui-test",
                "--body",
                "focus-regression"
            ],
            responseTimeoutSeconds: 4.0,
            cliStrategy: .bundledOnly
        )
    }

    func runCmuxCommand(
        socketPath: String,
        arguments: [String],
        responseTimeoutSeconds: Double = 3.0,
        cliStrategy: CmuxCLIStrategy = .any
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        var args = ["--socket", socketPath]
        args.append(contentsOf: arguments)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = String(responseTimeoutSeconds)

        let cliPaths = resolveCmuxCLIPaths(strategy: cliStrategy)
        if cliPaths.isEmpty, cliStrategy == .bundledOnly {
            return (
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to locate bundled cmux CLI"
            )
        }

        var lastPermissionFailure: (terminationStatus: Int32, stdout: String, stderr: String)?
        for cliPath in cliPaths {
            let result = executeCmuxCommand(
                executablePath: cliPath,
                arguments: args,
                environment: environment
            )
            if result.terminationStatus == 0 {
                return result
            }
            if result.stderr.localizedCaseInsensitiveContains("operation not permitted") {
                lastPermissionFailure = result
                continue
            }
            return result
        }

        if cliStrategy == .bundledOnly {
            return lastPermissionFailure ?? (
                terminationStatus: -1,
                stdout: "",
                stderr: "Bundled cmux CLI command failed without an executable path"
            )
        }

        let fallbackArgs = ["cmux"] + args
        let fallbackResult = executeCmuxCommand(
            executablePath: "/usr/bin/env",
            arguments: fallbackArgs,
            environment: environment
        )
        if fallbackResult.terminationStatus == 0 || lastPermissionFailure == nil {
            return fallbackResult
        }
        return lastPermissionFailure ?? fallbackResult
    }

    enum CmuxCLIStrategy: Equatable {
        case any
        case bundledOnly
    }

    func socketDiagnostics(from data: [String: String]) -> String {
        let pingResponse = data["socketPingResponse"].flatMap { $0.isEmpty ? nil : $0 } ?? "<nil>"
        return "mode=\(data["socketMode"] ?? "") running=\(data["socketIsRunning"] ?? "") " +
            "acceptLoopAlive=\(data["socketAcceptLoopAlive"] ?? "") pathMatches=\(data["socketPathMatches"] ?? "") " +
            "pathExists=\(data["socketPathExists"] ?? "") ping=\(pingResponse) " +
            "signals=\(data["socketFailureSignals"] ?? "")"
    }

    func resolveCmuxCLIPaths(strategy: CmuxCLIStrategy) -> [String] {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        var productDirectories: [String] = []

        if strategy == .any {
            for key in ["CMUX_UI_TEST_CLI_PATH", "CMUXTERM_CLI"] {
                if let value = env[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    candidates.append(value)
                }
            }
        }

        if let builtProductsDir = env["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            productDirectories.append(builtProductsDir)
        }

        if let hostPath = env["TEST_HOST"], !hostPath.isEmpty {
            let hostURL = URL(fileURLWithPath: hostPath)
            let productsDir = hostURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            productDirectories.append(productsDir)
        }

        productDirectories.append(contentsOf: inferredBuildProductsDirectories())
        for productsDir in uniquePaths(productDirectories) {
            appendCLIPathCandidates(fromProductsDirectory: productsDir, strategy: strategy, to: &candidates)
        }

        candidates.append("/tmp/cmux-\(launchTag)/Build/Products/Debug/cmux DEV.app/Contents/Resources/bin/cmux")
        candidates.append("/tmp/cmux-\(launchTag)/Build/Products/Debug/cmux.app/Contents/Resources/bin/cmux")
        if strategy == .any {
            candidates.append("/tmp/cmux-\(launchTag)/Build/Products/Debug/cmux")
        }

        var resolvedPaths: [String] = []
        for path in uniquePaths(candidates) {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            resolvedPaths.append(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
        }
        return uniquePaths(resolvedPaths)
    }

    private func inferredBuildProductsDirectories() -> [String] {
        let bundleURLs = [
            Bundle.main.bundleURL,
            Bundle(for: Self.self).bundleURL,
        ]

        return bundleURLs.compactMap { bundleURL in
            let standardizedPath = bundleURL.standardizedFileURL.path
            let components = standardizedPath.split(separator: "/")
            guard let productsIndex = components.firstIndex(of: "Products"),
                  productsIndex + 1 < components.count else {
                return nil
            }
            let prefixComponents = components.prefix(productsIndex + 2)
            return "/" + prefixComponents.joined(separator: "/")
        }
    }

    private func appendCLIPathCandidates(
        fromProductsDirectory productsDir: String,
        strategy: CmuxCLIStrategy,
        to candidates: inout [String]
    ) {
        candidates.append("\(productsDir)/cmux DEV.app/Contents/Resources/bin/cmux")
        candidates.append("\(productsDir)/cmux.app/Contents/Resources/bin/cmux")
        if strategy == .any {
            candidates.append("\(productsDir)/cmux")
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: productsDir) else {
            return
        }

        for entry in entries.sorted() where entry.hasSuffix(".app") {
            let cliPath = URL(fileURLWithPath: productsDir)
                .appendingPathComponent(entry)
                .appendingPathComponent("Contents/Resources/bin/cmux")
                .path
            candidates.append(cliPath)
        }
        if strategy == .any {
            for entry in entries.sorted() where entry == "cmux" {
                let cliPath = URL(fileURLWithPath: productsDir)
                    .appendingPathComponent(entry)
                    .path
                candidates.append(cliPath)
            }
        }
    }

    private func executeCmuxCommand(
        executablePath: String,
        arguments: [String],
        environment: [String: String]
    ) -> (terminationStatus: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (
                terminationStatus: -1,
                stdout: "",
                stderr: "Failed to run cmux command: \(error.localizedDescription) (cliPath=\(executablePath))"
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawStderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = rawStderr.isEmpty ? "" : "\(rawStderr) (cliPath=\(executablePath))"
        return (process.terminationStatus, stdout, stderr)
    }

    func isSocketPermissionFailure(_ stderr: String?) -> Bool {
        guard let stderr, !stderr.isEmpty else { return false }
        return stderr.localizedCaseInsensitiveContains("failed to connect to socket") &&
            stderr.localizedCaseInsensitiveContains("operation not permitted")
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths {
            if seen.insert(path).inserted {
                unique.append(path)
            }
        }
        return unique
    }

}
