import Foundation
import CmuxNativeLink
import CmuxNativeWire

/// Dispatches `svc` requests to the host services.
public struct HostServices: Sendable {
    public static let version = "0.1.0"

    public let guardrail: PathGuard
    public let files: FileService
    public let git: GitService
    public let refs: SessionRefsService
    public let uploadsRoot: String?
    public let daemonSocket: @Sendable () -> String?
    public let presence: PresenceBoard

    public init(guardrail: PathGuard = PathGuard(), uploadsRoot: String? = nil,
                daemonSocket: @escaping @Sendable () -> String? = { nil }, presence: PresenceBoard = PresenceBoard()) {
        self.presence = presence
        self.guardrail = guardrail
        self.files = FileService(guardrail: guardrail)
        self.git = GitService(guardrail: guardrail)
        self.refs = SessionRefsService(guardrail: guardrail)
        self.uploadsRoot = uploadsRoot
        self.daemonSocket = daemonSocket
    }

    public func hostInfo() -> HostInfo {
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let hostname = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return HostInfo(
            hostname: hostname, user: NSUserName(), home: guardrail.home,
            os: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", arch: machine,
            daemonSocket: daemonSocket(), version: Self.version
        )
    }

    /// Serves one `svc` channel until it closes. Requests run concurrently;
    /// responses carry their request `id`.
    public func serve(channel: any LinkChannel, peer: String? = nil, log: @escaping @Sendable (String) -> Void = { _ in }) async {
        let uploads = UploadService(guardrail: guardrail, uploadsRoot: uploadsRoot)
        let peerKey = peer ?? "svc-\(UUID().uuidString)"
        defer { presence.clear(peer: peerKey) }
        await withDiscardingTaskGroup { group in
            for await line in channel.incoming {
                group.addTask {
                    let response = await self.respond(to: line, uploads: uploads, peer: peerKey)
                    if let out = try? ServiceMessage.response(response).line() {
                        try? await channel.send(out)
                    }
                }
            }
        }
        await uploads.abortAll()
        log("svc channel ended")
    }

    public func respond(to line: Data, uploads: UploadService, peer: String = "local") async -> ServiceResponse {
        let request: ServiceRequest
        do { request = try JSONDecoder().decode(ServiceRequest.self, from: line) } catch {
            let id = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["id"] as? Int
            return ServiceResponse(id: id, error: .badRequest("expected {id, method, params}"))
        }
        if ServiceMethod(rawValue: request.method) == .presenceSet {
            guard let visible = request.params?["visible"]?.boolValue else {
                return ServiceResponse(id: request.id, error: .badRequest("presence.set needs {visible: bool}"))
            }
            presence.set(peer: peer, visible: visible)
            return ServiceResponse(id: request.id, result: ["visible": .bool(visible)])
        }
        do {
            return ServiceResponse(id: request.id, result: try await handle(request, uploads: uploads))
        } catch let error as ServiceError {
            return ServiceResponse(id: request.id, error: error)
        } catch let refusal as PathGuard.Refusal {
            return ServiceResponse(id: request.id, error: .forbidden(refusal.description))
        } catch is DecodingError {
            return ServiceResponse(id: request.id, error: .badRequest("bad params for \(request.method)"))
        } catch {
            return ServiceResponse(id: request.id, error: .failed("\(error)"))
        }
    }

    private func params<T: Decodable>(_ request: ServiceRequest, _ type: T.Type) throws -> T {
        try (request.params ?? .object([:])).decode(T.self)
    }

    func handle(_ request: ServiceRequest, uploads: UploadService) async throws -> JSONValue {
        switch ServiceMethod(rawValue: request.method) {
        case .hostInfo:
            return try JSONValue(encoding: hostInfo())
        case .fsList:
            return try JSONValue(encoding: files.list(params(request, PathParams.self)))
        case .fsStat:
            return try JSONValue(encoding: files.stat(params(request, PathParams.self)))
        case .fsRead:
            return try JSONValue(encoding: files.read(params(request, FSReadParams.self)))
        case .gitStatus:
            return try JSONValue(encoding: await git.status(params(request, GitCwdParams.self)))
        case .gitDiff:
            return try JSONValue(encoding: await git.diff(params(request, GitDiffParams.self)))
        case .gitLog:
            return try JSONValue(encoding: await git.log(params(request, GitLogParams.self)))
        case .uploadPut:
            return try JSONValue(encoding: await uploads.put(params(request, UploadPutParams.self)))
        case .uploadBegin:
            return try JSONValue(encoding: await uploads.begin(params(request, UploadBeginParams.self)))
        case .uploadChunk:
            return try await uploads.chunk(params(request, UploadChunkParams.self))
        case .uploadEnd:
            return try JSONValue(encoding: await uploads.end(params(request, UploadEndParams.self)))
        case .sessionRefs:
            return try JSONValue(encoding: refs.refs(params(request, SessionRefsParams.self)))
        // Feed is driven from daemon notifications on the phone for now.
        case .feedList:
            return ["items": []]
        case .feedSubscribe:
            return ["subscribed": false]
        case .feedReply, .feedAnswer:
            return ["accepted": false]
        default:
            throw ServiceError.unknownMethod(request.method)
        }
    }
}
