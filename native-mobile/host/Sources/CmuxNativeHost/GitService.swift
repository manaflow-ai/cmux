import Foundation
import CmuxNativeWire

/// `git.status`, `git.diff`, `git.log` via `/usr/bin/git -C <cwd>`.
public struct GitService: Sendable {
    public static let maximumDiffBytes = 4 << 20
    public static let maximumUntrackedFiles = 200

    public let guardrail: PathGuard
    let git: String
    let runner = ProcessRunner(extraEnvironment: [
        "GIT_PAGER": "cat", "PAGER": "cat", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C", "GIT_EXTERNAL_DIFF": "",
    ], maximumOutputBytes: GitService.maximumDiffBytes)

    public init(guardrail: PathGuard, git: String = "/usr/bin/git") {
        self.guardrail = guardrail
        self.git = git
    }

    private func run(_ cwd: String, _ args: [String], allow: Set<Int32> = [0]) async throws -> ProcessRunner.Output {
        let output = try await runner.run(git, ["-C", cwd, "--no-pager", "-c", "core.quotepath=off", "-c", "color.ui=false"] + args)
        guard allow.contains(output.status) else {
            throw ServiceError(code: "git_failed", message: output.stderrText.isEmpty ? "git exited \(output.status)" : output.stderrText)
        }
        return output
    }

    private func checkedCwd(_ cwd: String) throws -> String {
        let path = try guardrail.resolve(cwd)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ServiceError.notFound("\(cwd) is not a directory")
        }
        return path
    }

    private func root(_ cwd: String) async throws -> String {
        try await run(cwd, ["rev-parse", "--show-toplevel"]).stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: status

    public func status(_ params: GitCwdParams) async throws -> GitStatusResult {
        let cwd = try checkedCwd(params.cwd)
        let top = try await root(cwd)
        let out = try await run(cwd, ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all"])
        return Self.parseStatus(out.stdout, root: top)
    }

    static func parseStatus(_ data: Data, root: String) -> GitStatusResult {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        if fields.last == "" { fields.removeLast() }
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var files: [GitStatusFile] = []
        var i = 0
        while i < fields.count {
            let field = fields[i]
            i += 1
            if field.hasPrefix("## ") {
                (branch, upstream, ahead, behind) = parseBranchLine(String(field.dropFirst(3)))
                continue
            }
            guard field.count >= 4 else { continue }
            let chars = Array(field)
            let x = String(chars[0])
            let y = String(chars[1])
            let path = String(chars[3...])
            var oldPath: String?
            if x == "R" || x == "C" || y == "R" || y == "C", i < fields.count {
                oldPath = fields[i]
                i += 1
            }
            files.append(GitStatusFile(
                path: path, oldPath: oldPath, index: x, worktree: y, status: classify(x: x, y: y),
                staged: x != " " && x != "?" && x != "!", unstaged: y != " "
            ))
        }
        return GitStatusResult(root: root, branch: branch, upstream: upstream, ahead: ahead, behind: behind, files: files)
    }

    static func parseBranchLine(_ line: String) -> (String?, String?, Int, Int) {
        // "main...origin/main [ahead 1, behind 2]", "No commits yet on main", "HEAD (no branch)"
        var rest = line
        var ahead = 0
        var behind = 0
        if let bracket = rest.range(of: " [") {
            let info = rest[bracket.upperBound...].dropLast()
            for part in info.split(separator: ",") {
                let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
                if words.count == 2, let n = Int(words[1]) {
                    if words[0] == "ahead" { ahead = n } else if words[0] == "behind" { behind = n }
                }
            }
            rest = String(rest[..<bracket.lowerBound])
        }
        if rest.hasPrefix("No commits yet on ") { return (String(rest.dropFirst(18)), nil, 0, 0) }
        if rest.hasPrefix("HEAD (no branch)") { return (nil, nil, 0, 0) }
        let parts = rest.components(separatedBy: "...")
        return (parts[0], parts.count > 1 ? parts[1] : nil, ahead, behind)
    }

    static func classify(x: String, y: String) -> GitFileStatus {
        if x == "?" { return .untracked }
        if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { return .unmerged }
        for c in [x, y] {
            switch c {
            case "R": return .renamed
            case "C": return .copied
            default: break
            }
        }
        for c in [x, y] {
            switch c {
            case "A": return .added
            case "D": return .deleted
            case "T": return .typechange
            case "M": return .modified
            default: break
            }
        }
        return .unknown
    }

    // MARK: diff

    public func diff(_ params: GitDiffParams) async throws -> GitDiffResult {
        let cwd = try checkedCwd(params.cwd)
        if let base = params.base, base.hasPrefix("-") || base.isEmpty { throw ServiceError.badRequest("bad base ref") }
        let staged = params.staged ?? false
        var revision: [String] = ["-M"]
        if staged { revision.append("--cached") }
        if let base = params.base { revision.append(base) }
        let pathspec = ["--"] + (params.path.map { [$0] } ?? [])

        let text = try await run(cwd, ["diff", "--no-color", "--no-ext-diff"] + revision + pathspec)
        let numstat = try await run(cwd, ["diff", "--no-color", "--no-ext-diff", "--numstat", "-z"] + revision + pathspec)
        let nameStatus = try await run(cwd, ["diff", "--no-color", "--no-ext-diff", "--name-status", "-z"] + revision + pathspec)
        var diffText = text.stdoutText
        var truncated = text.truncated
        var files = Self.mergeStats(numstat: numstat.stdout, nameStatus: nameStatus.stdout)

        if !staged, params.untracked ?? true {
            let top = try await root(cwd)
            let listed = try await run(cwd, ["ls-files", "--others", "--exclude-standard", "-z", "--full-name"] + pathspec)
            let untracked = listed.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            for path in untracked.prefix(Self.maximumUntrackedFiles) {
                if diffText.utf8.count >= Self.maximumDiffBytes {
                    truncated = true
                    break
                }
                let one = try await run(top, ["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", path], allow: [0, 1])
                let stat = try await run(top, ["diff", "--no-ext-diff", "--no-index", "--numstat", "--", "/dev/null", path], allow: [0, 1])
                diffText += one.stdoutText
                let parts = stat.stdoutText.split(separator: "\t")
                let binary = parts.first == "-"
                files.append(GitDiffFile(path: path, oldPath: nil, status: .untracked,
                                         additions: binary ? 0 : Int(parts.first ?? "") ?? 0, deletions: 0, binary: binary))
            }
            if untracked.count > Self.maximumUntrackedFiles { truncated = true }
        }
        if diffText.utf8.count > Self.maximumDiffBytes {
            diffText = String(decoding: Data(diffText.utf8).prefix(Self.maximumDiffBytes), as: UTF8.self)
            truncated = true
        }
        return GitDiffResult(diff: diffText, files: files, truncated: truncated)
    }

    static func mergeStats(numstat: Data, nameStatus: Data) -> [GitDiffFile] {
        // --name-status -z: "M\0path\0" or "R100\0old\0new\0".
        var statusByPath: [String: (GitFileStatus, String?)] = [:]
        var order: [String] = []
        let ns = nameStatus.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < ns.count {
            let code = ns[i]
            i += 1
            guard let letter = code.first else { continue }
            let status: GitFileStatus = switch letter {
            case "A": .added
            case "D": .deleted
            case "M": .modified
            case "R": .renamed
            case "C": .copied
            case "T": .typechange
            case "U": .unmerged
            default: .unknown
            }
            if letter == "R" || letter == "C" {
                guard i + 1 < ns.count else { break }
                let old = ns[i]
                let new = ns[i + 1]
                i += 2
                statusByPath[new] = (status, old)
                order.append(new)
            } else {
                guard i < ns.count else { break }
                statusByPath[ns[i]] = (status, nil)
                order.append(ns[i])
                i += 1
            }
        }
        // --numstat -z: "add\tdel\tpath\0" or, for renames, "add\tdel\t\0old\0new\0".
        var stats: [String: (Int, Int, Bool)] = [:]
        let nm = numstat.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        i = 0
        while i < nm.count {
            let record = nm[i]
            i += 1
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let binary = parts[0] == "-"
            let adds = Int(parts[0]) ?? 0
            let dels = Int(parts[1]) ?? 0
            var path = String(parts[2])
            if path.isEmpty, i + 1 < nm.count {
                path = nm[i + 1]
                i += 2
            }
            stats[path] = (adds, dels, binary)
            if statusByPath[path] == nil {
                statusByPath[path] = (.modified, nil)
                order.append(path)
            }
        }
        return order.map { path in
            let (status, old) = statusByPath[path]!
            let (adds, dels, binary) = stats[path] ?? (0, 0, false)
            return GitDiffFile(path: path, oldPath: old, status: status, additions: adds, deletions: dels, binary: binary)
        }
    }

    // MARK: log

    public func log(_ params: GitLogParams) async throws -> GitLogResult {
        let cwd = try checkedCwd(params.cwd)
        let limit = min(max(params.limit ?? 50, 1), 500)
        let out = try await run(cwd, ["log", "-n", "\(limit)", "--no-color", "--format=%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%s%x1e"])
        let commits = out.stdoutText.split(separator: "\u{1e}").compactMap { record -> GitCommit? in
            let f = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6 else { return nil }
            return GitCommit(sha: f[0], shortSha: f[1], author: f[2], email: f[3], time: Double(f[4]) ?? 0, subject: f[5])
        }
        return GitLogResult(commits: commits)
    }
}
