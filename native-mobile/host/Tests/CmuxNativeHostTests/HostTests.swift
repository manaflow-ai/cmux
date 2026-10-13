import Foundation
import Testing
import CmuxNativeLink
import CmuxNativeWire
@testable import CmuxNativeHost

func line(_ s: String) -> Data { Data(s.utf8) }

func errorObject(_ verdict: DaemonChannelPolicy.Verdict) -> [String: Any]? {
    guard case .refuse(let data) = verdict else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@Suite struct DaemonChannelPolicyTests {
    let policy = DaemonChannelPolicy(deviceID: "dev1")

    @Test func allowsTerminalCommands() {
        for cmd in ["identify", "list-workspaces", "attach-surface", "send", "send-key", "read-screen", "copy", "subscribe"] {
            #expect(policy.evaluate(line(#"{"id":1,"cmd":"\#(cmd)"}"#)) == .forward, "\(cmd)")
        }
    }

    @Test func refusesUnlistedCommandsWithV12Error() throws {
        for cmd in ["run", "create-surface-with-receipt", "shutdown", "set-config", "future-command"] {
            let refusal = try #require(errorObject(policy.evaluate(line(#"{"id":7,"cmd":"\#(cmd)"}"#))))
            #expect(refusal["ok"] as? Bool == false)
            #expect(refusal["id"] as? Int == 7)
            #expect(refusal["error_code"] as? String == "forbidden")
            #expect(refusal["error"] as? String == "\(cmd) is not available to a phone")
        }
        // Exact bytes of the refusal line.
        guard case .refuse(let data) = policy.evaluate(line(#"{"id":3,"cmd":"run"}"#)) else { Issue.record("not refused"); return }
        #expect(String(decoding: data, as: UTF8.self) == #"{"error":"run is not available to a phone","error_code":"forbidden","id":3,"ok":false}"#)
    }

    @Test func refusalWithoutIDCarriesNull() throws {
        guard case .refuse(let data) = policy.evaluate(line("not json")) else { Issue.record("not refused"); return }
        #expect(String(decoding: data, as: UTF8.self).contains(#""id":null"#))
        let missing = try #require(errorObject(policy.evaluate(line(#"{"id":"a"}"#))))
        #expect(missing["error_code"] as? String == "bad_request")
        #expect(missing["id"] as? String == "a")
    }

    @Test func creationCommandsRefuseProgramFields() throws {
        #expect(policy.evaluate(line(#"{"id":1,"cmd":"new-tab","pane":3,"cols":80,"rows":24}"#)) == .forward)
        for field in ["argv", "command", "cwd", "env"] {
            let refusal = try #require(errorObject(policy.evaluate(line(#"{"id":1,"cmd":"new-tab","\#(field)":"x"}"#))))
            #expect(refusal["error_code"] as? String == "forbidden")
            #expect((refusal["error"] as? String)?.contains(field) == true)
        }
        #expect(errorObject(policy.evaluate(line(#"{"id":1,"cmd":"create-terminal","workspace":1,"cwd":"/"}"#))) != nil)
        #expect(policy.evaluate(line(#"{"id":1,"cmd":"create-workspace","name":"a","key":"k","origin":"o","mutation_id":"m"}"#)) == .forward)
    }

    @Test func projectionsAreScopedToTheDevice() {
        #expect(policy.evaluate(line(#"{"id":1,"cmd":"get-frontend-projection","scope":"shared"}"#)) == .forward)
        #expect(policy.evaluate(line(#"{"id":1,"cmd":"put-frontend-projection","scope":"personal","subject_key":"ios-device:dev1"}"#)) == .forward)
        #expect(errorObject(policy.evaluate(line(#"{"id":1,"cmd":"put-frontend-projection","scope":"shared"}"#))) != nil)
        #expect(errorObject(policy.evaluate(line(#"{"id":1,"cmd":"get-frontend-projection","scope":"personal","subject_key":"ios-device:other"}"#))) != nil)
    }

    @Test func oversizeLineIsRefused() throws {
        var big = Data(#"{"id":1,"cmd":"send","text":""#.utf8)
        big.append(Data(repeating: 0x61, count: DaemonChannelPolicy.maximumLineBytes))
        big.append(Data(#""}"#.utf8))
        #expect(errorObject(policy.evaluate(big))?["error_code"] as? String == "too_large")
    }

    /// Pins the mirror against the Mac app's `DaemonLanePolicy` source when
    /// it is present in the same checkout.
    @Test func mirrorsDaemonLanePolicySource() throws {
        let here = URL(fileURLWithPath: #filePath)
        let source = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift")
        guard let text = try? String(contentsOf: source, encoding: .utf8) else { return }
        let start = try #require(text.range(of: "allowedCommands: Set<String> = ["))
        let end = try #require(text.range(of: "]", range: start.upperBound..<text.endIndex))
        let names = Set(text[start.upperBound..<end.lowerBound].matches(of: /"([a-z0-9-]+)"/).map { String($0.1) })
        #expect(names == DaemonChannelPolicy.allowedCommands)
    }
}

@Suite struct PathGuardTests {
    let home: String
    let guardrail: PathGuard

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "pg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "home/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "outside"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(path: "outside/secret.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "home/escape").path,
                                                   withDestinationPath: root.appending(path: "outside").path)
        try FileManager.default.createSymbolicLink(atPath: root.appending(path: "home/inner").path,
                                                   withDestinationPath: root.appending(path: "home/sub").path)
        home = root.appending(path: "home").path
        // No extra roots, so the temp dir itself is not allowed.
        guardrail = PathGuard(home: home, extraRoots: [])
    }

    @Test func allowsHomeAndRelativePaths() throws {
        #expect(try guardrail.resolve("~") == guardrail.home)
        #expect(try guardrail.resolve("~/sub") == guardrail.home + "/sub")
        #expect(try guardrail.resolve("sub") == guardrail.home + "/sub")
        #expect(try guardrail.resolve("x.txt", relativeTo: "~/sub") == guardrail.home + "/sub/x.txt")
        #expect(try guardrail.resolve("~/missing/deeper") == guardrail.home + "/missing/deeper")
    }

    @Test func refusesOutsideHome() {
        #expect(throws: PathGuard.Refusal.self) { try guardrail.resolve("/etc/hosts") }
        #expect(throws: PathGuard.Refusal.self) { try guardrail.resolve("~/../outside/secret.txt") }
        #expect(throws: PathGuard.Refusal.self) { try guardrail.resolve("/") }
    }

    @Test func resolvesSymlinksBeforeChecking() throws {
        #expect(throws: PathGuard.Refusal.self) { try guardrail.resolve("~/escape/secret.txt") }
        #expect(throws: PathGuard.Refusal.self) { try guardrail.resolve("~/escape/new-file") }
        #expect(try guardrail.resolve("~/inner") == guardrail.home + "/sub")
    }

    @Test func prefixSiblingIsNotInside() {
        let sibling = guardrail.home + "-evil"
        try? FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        #expect(throws: PathGuard.Refusal.self) { try guardrail.resolve(sibling) }
    }

    @Test func tmpIsAllowedByDefault() throws {
        let g = PathGuard(home: home)
        #expect(try g.resolve("/tmp") == "/private/tmp")
        #expect(try g.resolve("/tmp/whatever.txt") == "/private/tmp/whatever.txt")
        #expect(try g.resolve("/private/tmp/a") == "/private/tmp/a")
        #expect(throws: PathGuard.Refusal.self) { try g.resolve("/var/log") }
    }
}

@Suite struct DaemonSocketLocatorTests {
    @Test func runtimeRootOrder() {
        #expect(DaemonSocketLocator(environment: ["XDG_RUNTIME_DIR": "/x", "TMPDIR": "/t/"], uid: 501).runtimeRoot == "/x")
        #expect(DaemonSocketLocator(environment: ["XDG_RUNTIME_DIR": "", "TMPDIR": "/t/"], uid: 501).runtimeRoot == "/t/")
        #expect(DaemonSocketLocator(environment: [:], uid: 501).runtimeRoot == "/tmp")
        let l = DaemonSocketLocator(environment: ["TMPDIR": "/var/folders/ab/T/"], uid: 501)
        #expect(l.candidates(session: "cmux-app-dev") == ["/var/folders/ab/T/cmux-tui-501/cmux-app-dev.sock", "/tmp/cmux-tui-501/cmux-app-dev.sock"])
        #expect(DaemonSocketLocator(environment: [:], uid: 501).socketDirectories == ["/tmp/cmux-tui-501"])
    }

    @Test func explicitAndEnvironmentWin() {
        #expect(DaemonSocketLocator(explicitPath: "/a.sock", environment: ["CMUX_TUI_SOCKET": "/b.sock"]).resolve() == "/a.sock")
        #expect(DaemonSocketLocator(environment: ["CMUX_TUI_SOCKET": "/b.sock"]).resolve() == "/b.sock")
    }

    @Test func picksNewestSocketWithoutSession() throws {
        // sun_path is short; keep the root short.
        let root = "/tmp/nl-\(UUID().uuidString.prefix(6))"
        let dir = "\(root)/cmux-tui-501"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let old = try bindSocket("\(dir)/old.sock")
        let new = try bindSocket("\(dir)/cmux-app-x.sock")
        defer { close(old); close(new) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: "\(dir)/old.sock")
        FileManager.default.createFile(atPath: "\(dir)/not-a-socket.sock", contents: Data())
        let locator = DaemonSocketLocator(environment: ["TMPDIR": root], uid: 501)
        #expect(locator.resolve() == "\(dir)/cmux-app-x.sock")
        #expect(DaemonSocketLocator(session: "old", environment: ["TMPDIR": root], uid: 501).resolve() == "\(dir)/old.sock")
        #expect(DaemonSocketLocator(session: "nope", environment: ["TMPDIR": root], uid: 501).resolve() == nil)
    }

    func bindSocket(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard r == 0 else { throw CocoaError(.fileWriteUnknown) }
        return fd
    }
}

@Suite struct GitParsingTests {
    @Test func parsesPorcelainStatus() {
        let raw = "## main...origin/main [ahead 2, behind 1]\0 M a.swift\0A  b.swift\0R  new.swift\0old.swift\0?? c.txt\0UU d.swift\0"
        let r = GitService.parseStatus(Data(raw.utf8), root: "/r")
        #expect(r.branch == "main" && r.upstream == "origin/main" && r.ahead == 2 && r.behind == 1)
        #expect(r.files.map(\.path) == ["a.swift", "b.swift", "new.swift", "c.txt", "d.swift"])
        #expect(r.files.map(\.status) == [.modified, .added, .renamed, .untracked, .unmerged])
        #expect(r.files[2].oldPath == "old.swift")
        #expect(r.files[0].unstaged && !r.files[0].staged)
        #expect(r.files[1].staged && !r.files[1].unstaged)
    }

    @Test func mergesNumstatAndNameStatus() {
        let ns = "M\0a.swift\0R087\0old.txt\0new.txt\0A\0img.png\0"
        let num = "3\t1\ta.swift\0" + "1\t1\t\0old.txt\0new.txt\0" + "-\t-\timg.png\0"
        let files = GitService.mergeStats(numstat: Data(num.utf8), nameStatus: Data(ns.utf8))
        #expect(files == [
            GitDiffFile(path: "a.swift", oldPath: nil, status: .modified, additions: 3, deletions: 1, binary: false),
            GitDiffFile(path: "new.txt", oldPath: "old.txt", status: .renamed, additions: 1, deletions: 1, binary: false),
            GitDiffFile(path: "img.png", oldPath: nil, status: .added, additions: 0, deletions: 0, binary: true),
        ])
    }
}

@Suite struct ServiceTests {
    let root: URL
    let services: HostServices

    init() throws {
        let dir = "/tmp/nsvc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir + "/repo/src", withIntermediateDirectories: true)
        root = URL(fileURLWithPath: PathGuard.realpath(dir)!)
        services = HostServices(guardrail: PathGuard(home: root.path, extraRoots: []), uploadsRoot: root.appending(path: "uploads").path)
    }

    func call(_ method: String, _ params: JSONValue) async -> ServiceResponse {
        let request = ServiceRequest(id: 1, method: method, params: params)
        return await services.respond(to: try! JSONEncoder().encode(request), uploads: UploadService(guardrail: services.guardrail, uploadsRoot: services.uploadsRoot))
    }

    func git(_ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.appending(path: "repo").path] + args
        p.environment = ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t", "HOME": root.path]
        try p.run()
        p.waitUntilExit()
    }

    @Test func fsListReadAndRefusal() async throws {
        try Data("hello".utf8).write(to: root.appending(path: "repo/README.md"))
        let list = await call("fs.list", ["path": "~/repo"])
        let names = list.result?["entries"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
        #expect(names == ["src", "README.md"])
        #expect(list.result?["entries"]?.arrayValue?.last?["mime"] == "text/markdown")
        let read = await call("fs.read", ["path": "~/repo/README.md"])
        #expect(read.result?["data"]?.stringValue == Data("hello".utf8).base64EncodedString())
        #expect(read.result?["size"]?.intValue == 5)
        let refused = await call("fs.read", ["path": "/etc/hosts"])
        #expect(refused.error?.code == "forbidden")
        let unknown = await call("nope.method", [:])
        #expect(unknown.error?.code == "unknown_method")
    }

    @Test func gitDiffIncludesUntrackedAsNewFiles() async throws {
        try git("init", "-q", "-b", "main")
        try Data("one\n".utf8).write(to: root.appending(path: "repo/a.txt"))
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "first")
        try Data("one\ntwo\n".utf8).write(to: root.appending(path: "repo/a.txt"))
        try Data("new\nfile\n".utf8).write(to: root.appending(path: "repo/src/b.txt"))
        let status = await call("git.status", ["cwd": "~/repo/src"])
        #expect(status.result?["branch"] == "main")
        #expect(status.result?["files"]?.arrayValue?.count == 2)
        let diff = await call("git.diff", ["cwd": "~/repo/src"])
        let files = diff.result?["files"]?.arrayValue ?? []
        #expect(files.map { $0["path"]?.stringValue ?? "" } == ["a.txt", "src/b.txt"])
        #expect(files.map { $0["status"]?.stringValue ?? "" } == ["modified", "untracked"])
        #expect(files.map { $0["additions"]?.intValue ?? -1 } == [1, 2])
        let text = diff.result?["diff"]?.stringValue ?? ""
        #expect(text.contains("+two") && text.contains("new file mode") && text.contains("+file"))
        let staged = await call("git.diff", ["cwd": "~/repo", "staged": true])
        #expect(staged.result?["files"]?.arrayValue?.isEmpty == true)
        let bad = await call("git.diff", ["cwd": "~/repo", "base": "--output=/tmp/x"])
        #expect(bad.error?.code == "bad_request")
        let log = await call("git.log", ["cwd": "~/repo", "limit": 5])
        #expect(log.result?["commits"]?.arrayValue?.first?["subject"] == "first")
    }

    @Test func gitShowReturnsCommittedAndIndexBytes() async throws {
        try git("init", "-q", "-b", "main")
        let v1 = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x01])
        try v1.write(to: root.appending(path: "repo/logo.png"))
        try git("add", "logo.png")
        try git("commit", "-q", "-m", "logo")
        let v2 = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x02, 0x03])
        try v2.write(to: root.appending(path: "repo/logo.png"))
        try git("add", "logo.png")
        let head = await call("git.show", ["cwd": "~/repo/src", "path": "logo.png", "rev": "HEAD"])
        #expect(head.result?["data"]?.stringValue == v1.base64EncodedString())
        #expect(head.result?["size"]?.intValue == v1.count)
        let index = await call("git.show", ["cwd": "~/repo", "path": "logo.png"])
        #expect(index.result?["data"]?.stringValue == v2.base64EncodedString())
        let missing = await call("git.show", ["cwd": "~/repo", "path": "nope.png", "rev": "HEAD"])
        #expect(missing.error?.code == "not_found")
        for rev in ["--output=/tmp/x", "", "HEAD;rm"] {
            let bad = await call("git.show", ["cwd": "~/repo", "path": "logo.png", "rev": .string(rev)])
            #expect(bad.error?.code == "bad_request", "rev \(rev)")
        }
        for path in ["/etc/hosts", "../x", ""] {
            let bad = await call("git.show", ["cwd": "~/repo", "path": .string(path), "rev": "HEAD"])
            #expect(bad.error?.code == "bad_request", "path \(path)")
        }
    }

    @Test func uploadPutAndChunked() async throws {
        let uploads = UploadService(guardrail: services.guardrail, uploadsRoot: services.uploadsRoot)
        let put = try await uploads.put(UploadPutParams(name: "../../evil/../photo.jpg", dataB64: Data("abc".utf8).base64EncodedString()))
        #expect(put.path.hasPrefix(root.appending(path: "uploads").path))
        #expect((put.path as NSString).lastPathComponent == "photo.jpg")
        let again = try await uploads.put(UploadPutParams(name: "photo.jpg", dataB64: Data("abc".utf8).base64EncodedString()))
        #expect((again.path as NSString).lastPathComponent == "photo 2.jpg")
        let begin = try await uploads.begin(UploadBeginParams(name: "big.bin", size: 6))
        _ = try await uploads.chunk(UploadChunkParams(uploadID: begin.uploadID, offset: 0, dataB64: Data("abc".utf8).base64EncodedString()))
        await #expect(throws: ServiceError.self) {
            try await uploads.chunk(UploadChunkParams(uploadID: begin.uploadID, offset: 0, dataB64: Data("x".utf8).base64EncodedString()))
        }
        _ = try await uploads.chunk(UploadChunkParams(uploadID: begin.uploadID, offset: 3, dataB64: Data("def".utf8).base64EncodedString()))
        let done = try await uploads.end(UploadEndParams(uploadID: begin.uploadID))
        #expect(done.size == 6)
        #expect(try String(contentsOfFile: done.path, encoding: .utf8) == "abcdef")
        #expect((done.path as NSString).lastPathComponent == "big.bin")
    }

    @Test func sessionRefsFindsExistingPathsAndURLs() async throws {
        try Data("x".utf8).write(to: root.appending(path: "repo/README.md"))
        try Data("x".utf8).write(to: root.appending(path: "repo/src/main.swift"))
        let text = "Updated README.md and src/main.swift:12:3 (see `src/`), missing.txt, https://cmux.com/docs. /etc/hosts"
        let r = await call("session.refs", ["cwd": "~/repo", "text": .string(text)])
        let refs = r.result?["refs"]?.arrayValue ?? []
        let summary = refs.map { "\($0["kind"]?.stringValue ?? ""):\(($0["path"]?.stringValue ?? "").replacingOccurrences(of: root.path, with: ""))" }
        #expect(summary == ["file:/repo/README.md", "file:/repo/src/main.swift", "dir:/repo/src", "url:https://cmux.com/docs"])
    }
}

@Suite struct BridgeTests {
    /// A fake daemon on a Unix socket that echoes each line with `"seen":true`.
    @Test func daemonChannelSplicesAndRefuses() async throws {
        let path = "/tmp/nb-\(UUID().uuidString.prefix(6)).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        listen(listener, 4)
        defer { close(listener); unlink(path) }
        Thread.detachNewThread {
            let fd = accept(listener, nil, nil)
            var pending = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                pending.append(contentsOf: buf[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    var reply = Data(pending[..<nl].dropLast())
                    pending = Data(pending[(nl + 1)...])
                    reply.append(Data(#","seen":true}"#.utf8))
                    reply.append(0x0A)
                    _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                }
            }
            close(fd)
        }

        let acceptor = LoopbackHostAcceptor()
        let service = NativeHostService(acceptor: acceptor, configuration: .init(locator: DaemonSocketLocator(explicitPath: path)))
        await service.start()
        let link = LoopbackHostLink(port: try await acceptor.port())
        let client = ChannelClient(channel: try await link.openChannel(label: "daemon:test"))
        let ok = try await client.request(["cmd": "identify"])
        #expect(ok["seen"] == true)
        let refused = try await client.request(["cmd": "run", "argv": ["x"]])
        #expect(refused["error_code"] == "forbidden")
        #expect(refused["seen"] == nil)
        // A 1 MiB line crosses the link fragmented and reaches the daemon whole.
        let big = try await client.request(["cmd": "send", "surface": 1, "text": .string(String(repeating: "q", count: 1 << 20))])
        #expect(big["seen"] == true && big["text"]?.stringValue?.count == 1 << 20)
        link.close()
        await service.stop()
    }
}
