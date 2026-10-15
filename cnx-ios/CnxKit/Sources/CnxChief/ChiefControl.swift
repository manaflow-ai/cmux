import CnxTransport
import Foundation

/// The brain's engine report (`chief.engine.get`, cmux-tui
/// resource-api-v2.md "Chief control"): the same fields the Mac's Chief
/// settings read (`ChiefEngineReport` in CmuxNextDaemon).
public struct ChiefEngineReport: Decodable, Sendable, Equatable {
    public struct Engine: Decodable, Sendable, Equatable {
        public var harness: String?
        public var model: String?
        public var effort: String?

        public init(harness: String? = nil, model: String? = nil, effort: String? = nil) {
            self.harness = harness
            self.model = model
            self.effort = effort
        }
    }

    public struct Turn: Decodable, Sendable, Equatable {
        public var harness: String?
        public var model: String?
        public var status: String?
        public var ms: Double?
        public var tools: Int?
        public var costUSD: Double?
        public var reply: String?

        enum CodingKeys: String, CodingKey {
            case harness, model, status, ms, tools, reply
            case costUSD = "cost_usd"
        }
    }

    public struct Model: Decodable, Sendable, Equatable, Hashable {
        public var id: String
        public var name: String
    }

    public struct Offered: Decodable, Sendable, Equatable {
        public var models: [Model] = []
        public var efforts: [String] = []

        public init(models: [Model] = [], efforts: [String] = []) {
            self.models = models
            self.efforts = efforts
        }

        enum CodingKeys: String, CodingKey { case models, efforts }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            models = try c.decodeIfPresent([Model].self, forKey: .models) ?? []
            efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
        }
    }

    /// What turns run on (the saved choice over the brain's defaults).
    public var engine: Engine
    /// What the owner chose; nil fields follow the brain's default.
    public var choice: Engine
    /// The newest turn ends, newest first.
    public var recent: [Turn]
    public var offered: Offered
    /// Chief's avatar text from the Mac's `optchat/profile.json`, when the
    /// Mac's reply carries an `avatar` key (`avatarSupported`); nil or empty
    /// is the default, "C". A picture's file name is not avatar text.
    public var avatar: String?
    /// Whether this Mac reads and sets the avatar (`chief.engine.get` has an
    /// `avatar` key, `chief.engine.set` takes one). Older Macs do not.
    public var avatarSupported: Bool

    enum CodingKeys: String, CodingKey { case engine, choice, recent, offered, avatar }

    public init(engine: Engine, choice: Engine = Engine(), recent: [Turn] = [], offered: Offered = Offered(),
                avatar: String? = nil, avatarSupported: Bool = false) {
        self.engine = engine
        self.choice = choice
        self.recent = recent
        self.offered = offered
        self.avatar = avatar
        self.avatarSupported = avatarSupported
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = try c.decode(Engine.self, forKey: .engine)
        choice = try c.decodeIfPresent(Engine.self, forKey: .choice) ?? Engine()
        recent = try c.decodeIfPresent([Turn].self, forKey: .recent) ?? []
        offered = try c.decodeIfPresent(Offered.self, forKey: .offered) ?? Offered()
        avatarSupported = c.contains(.avatar)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar).flatMap(Self.avatarText)
    }

    /// Avatar text as Chief is drawn: trimmed, at most two characters, and
    /// never a picture's file name (`cat.png`); nil when there is none.
    public static func avatarText(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pictureExtensions = ["png", "jpg", "jpeg", "heic"]
        if !text.contains("/"), pictureExtensions.contains((text as NSString).pathExtension.lowercased()) { return nil }
        return String(text.prefix(2))
    }

    /// acpmux's own "default" model entry, which names what it resolves to
    /// ("Default (GPT-6.1 Sol)"); the pickers list it first, as on the Mac.
    public var defaultModel: Model? { offered.models.first { $0.id == "default" } }

    /// The models to pick, without acpmux's "default" entry.
    public var pickableModels: [Model] { offered.models.filter { $0.id != "default" } }

    /// A model id's display name, from what the Mac offers.
    public func modelName(_ id: String?) -> String? {
        guard let id, id != "default" else { return nil }
        return offered.models.first { $0.id == id }?.name
    }

    /// The harnesses the Mac's picker offers (HomeChiefSidebar): Claude and
    /// Codex, plus the current one when it is another (a CodeRouter route).
    public var harnesses: [String] {
        var list = ["claude", "codex"]
        if let current = engine.harness, !list.contains(current) { list.append(current) }
        return list
    }
}

/// Why a Chief control request failed, in words the settings page shows.
public struct ChiefControlError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: String
    public var reason: String?
    public var message: String

    public var description: String {
        switch (code, reason) {
        case ("origin.forbidden", _): return String(localized: "This Mac does not let a phone change Chief.")
        case (_, "not_configured"?): return String(localized: "Chief isn't running on this Mac. Open Home in cmux on the Mac to start it.")
        case (_, "unavailable"?): return String(localized: "Chief isn't answering on this Mac.")
        default: return message.isEmpty ? code : message
        }
    }
}

/// `chief.engine.get`, `chief.engine.set` and `chief.stop` over the phone's
/// `chief` channel: the Mac's ChiefControlClient requests, carried by
/// cnx-hostd's Chief policy to the Chief owner, which forwards them to the
/// brain (the only writer of its engine file).
public struct ChiefControl: Sendable {
    let client: DaemonClient

    public init(client: DaemonClient) {
        self.client = client
    }

    public func engine() async throws -> ChiefEngineReport {
        try await request("chief.engine.get", mutation: false)
    }

    /// Absent fields stay; "default" clears one (as on the Mac).
    /// `avatar` is sent only to a Mac whose report has `avatarSupported`.
    public func setEngine(harness: String? = nil, model: String? = nil, effort: String? = nil,
                          avatar: String? = nil) async throws -> ChiefEngineReport {
        var params: [String: Any] = [:]
        if let harness { params["harness"] = harness }
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        if let avatar { params["avatar"] = avatar }
        return try await request("chief.engine.set", params: params, mutation: true,
                                 key: "cnx-ios-chief-engine-" + UUID().uuidString.lowercased())
    }

    /// True when a running turn was stopped.
    public func stop() async throws -> Bool {
        struct Stopped: Decodable { var stopped: Bool }
        let result: Stopped = try await request("chief.stop", mutation: true, key: "cnx-ios-chief-stop-" + UUID().uuidString.lowercased())
        return result.stopped
    }

    private func request<T: Decodable>(_ operation: String, params: sending [String: Any] = [:], mutation: Bool, key: String? = nil) async throws -> T {
        let line = try await client.resourceRequest(operation, params: params, idempotencyKey: key)
        return try Self.decode(line, mutation: mutation)
    }

    /// A v2 response: `result` (a mutation's under `value`), or the error.
    static func decode<T: Decodable>(_ line: Data, mutation: Bool) throws -> T {
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw ChiefControlError(code: "malformed", reason: nil, message: "bad Chief control reply")
        }
        if object["ok"] as? Bool != true {
            let error = object["error"] as? [String: Any] ?? [:]
            let details = error["details"] as? [String: Any]
            let extra = (details?["extra"] as? [String: Any])?["message"] as? String ?? details?["message"] as? String
            // A v12 refusal (an older host) carries `error` as text.
            let text = error["message"] as? String ?? object["error"] as? String ?? ""
            throw ChiefControlError(code: error["code"] as? String ?? object["error_code"] as? String ?? "failed",
                                    reason: details?["reason"] as? String, message: extra ?? text)
        }
        var result = object["result"]
        if mutation { result = (result as? [String: Any])?["value"] }
        let data = try JSONSerialization.data(withJSONObject: result ?? [:])
        return try JSONDecoder().decode(T.self, from: data)
    }
}
