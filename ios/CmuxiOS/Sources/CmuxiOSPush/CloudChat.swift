import Foundation
import CmuxMobileRPC
import SwiftUI
import UIKit

/// A Cloud chat that can be opened on the phone through the Mac relay.
public struct CloudChatSession: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let machineID: String
    public let state: String
    public let updatedAt: Date?

    public init(id: String, title: String, machineID: String, state: String = "active", updatedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.machineID = machineID
        self.state = state
        self.updatedAt = updatedAt
    }
}

public struct CloudChatMessage: Codable, Equatable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, system, tool }

    public let id: String
    public let role: Role
    public let text: String
    public let createdAt: Date?

    public init(id: String, role: Role, text: String, createdAt: Date? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// The one seam between the iOS surface and the Mac's `mobile.chat.*` relay.
/// A transport may be backed by MobileCoreRPCClient, an offline fixture, or a
/// future direct Cloud connection without changing this UI.
public protocol CloudChatTransport: Sendable {
    func sessions() async throws -> [CloudChatSession]
    func history(sessionID: String) async throws -> [CloudChatMessage]
    func send(sessionID: String, text: String) async throws -> CloudChatMessage
}

/// Adapts the JSON response of the L3 relay to the typed iOS surface.
public struct CloudChatRPCTransport: CloudChatTransport {
    public typealias Request = @Sendable (_ method: String, _ params: [String: Any]) async throws -> Data
    private let request: Request

    public init(request: @escaping Request) { self.request = request }

    /// Production adapter for the paired-Mac L3 relay. The request envelope
    /// is encoded by the shared RPC client so auth, attach-ticket context and
    /// transport retries stay in the existing mobile path.
    public init(client: MobileCoreRPCClient) {
        self.init { method, params in
            let request = try MobileCoreRPCClient.requestData(method: method, params: params)
            return try await client.sendRequest(request)
        }
    }

    public func sessions() async throws -> [CloudChatSession] {
        let data = try await request("mobile.chat.sessions", [:])
        return try decodeEnvelope(data, key: "sessions")
    }

    public func history(sessionID: String) async throws -> [CloudChatMessage] {
        let data = try await request("mobile.chat.history", ["session_id": sessionID])
        return try decodeEnvelope(data, key: "messages")
    }

    public func send(sessionID: String, text: String) async throws -> CloudChatMessage {
        let data = try await request("mobile.chat.send", ["session_id": sessionID, "text": text])
        if let message = try? JSONDecoder.cloud.decode(CloudChatMessage.self, from: data) { return message }
        let object = try object(data)
        if let value = object["message"] {
            return try JSONDecoder.cloud.decode(CloudChatMessage.self, from: JSONSerialization.data(withJSONObject: value))
        }
        // The relay may acknowledge an accepted prompt before the assistant
        // response exists. Keep the local transcript truthful and let the
        // next history refresh fill in the eventual assistant message.
        guard object["accepted"] as? Bool == true else { throw CloudChatError.invalidResponse }
        let id = object["prompt_id"] as? String ?? UUID().uuidString
        return CloudChatMessage(id: id, role: .user, text: text)
    }

    private func decodeEnvelope<T: Decodable>(_ data: Data, key: String) throws -> T {
        if let value = try? JSONDecoder.cloud.decode(T.self, from: data) { return value }
        let object = try object(data)
        guard let value = object[key] else { throw CloudChatError.invalidResponse }
        return try JSONDecoder.cloud.decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudChatError.invalidResponse
        }
        return value
    }
}

public enum CloudChatError: Error, Equatable, Sendable { case invalidResponse, emptyMessage }

private extension JSONDecoder {
    static let cloud: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Main-actor state for the Cloud chat screen. It deliberately owns no
/// transport or account state, so a relay can be replaced while the screen is
/// open without leaking credentials into UIKit.
@MainActor
public final class CloudChatViewModel: ObservableObject {
    @Published public private(set) var sessions: [CloudChatSession] = []
    @Published public private(set) var messages: [CloudChatMessage] = []
    @Published public private(set) var selectedSessionID: String?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let transport: any CloudChatTransport
    private let preferredSessionID: String?

    public init(transport: any CloudChatTransport, preferredSessionID: String? = nil) {
        self.transport = transport
        self.preferredSessionID = preferredSessionID
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await transport.sessions()
            let targetID = preferredSessionID ?? selectedSessionID
            if let targetID, let target = sessions.first(where: { $0.id == targetID }) {
                await select(target)
            } else if let first = sessions.first {
                await select(first)
            }
            errorMessage = nil
        } catch { errorMessage = "Cloud chats are unavailable right now." }
    }

    public func select(_ session: CloudChatSession) async {
        selectedSessionID = session.id
        await loadHistory(sessionID: session.id)
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let selectedSessionID else { return }
        do {
            let sent = try await transport.send(sessionID: selectedSessionID, text: trimmed)
            messages.append(sent)
            errorMessage = nil
        } catch { errorMessage = "Your message could not be sent. Try again." }
    }

    private func loadHistory(sessionID: String) async {
        do {
            messages = try await transport.history(sessionID: sessionID)
            errorMessage = nil
        } catch { errorMessage = "This chat's history is unavailable right now." }
    }
}

/// A small native screen for reading and steering a Cloud chat.
public struct CloudChatView: View {
    @ObservedObject private var model: CloudChatViewModel
    @State private var draft = ""

    public init(model: CloudChatViewModel) { self.model = model }

    public var body: some View {
        NavigationStack {
            Group {
                if model.sessions.isEmpty {
                    ContentUnavailableView("No Cloud chats", systemImage: "cloud", description: Text("Start a chat on your Mac to see it here."))
                } else {
                    chatContent
                }
            }
            .navigationTitle("Cloud")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Refresh") { Task { await model.load() } } } }
        }
        .task { await model.load() }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            Picker("Chat", selection: Binding(get: { model.selectedSessionID ?? model.sessions[0].id }, set: { id in
                guard let session = model.sessions.first(where: { $0.id == id }) else { return }
                Task { await model.select(session) }
            })) {
                ForEach(model.sessions) { session in Text(session.title).tag(session.id) }
            }
            .pickerStyle(.menu)
            .padding(.horizontal)
            List(model.messages) { message in
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    Text(message.text)
                }
                .listRowSeparator(.hidden)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Cloud…", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("Send") { let text = draft; draft = ""; Task { await model.send(text) } }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
    }
}

public extension CloudChatViewModel {
    /// Presents the screen from UIKit without coupling the model to a
    /// navigation controller. Callers decide where the screen belongs.
    func viewController() -> UIViewController { UIHostingController(rootView: CloudChatView(model: self)) }
}

/// A push payload that should open a Cloud chat and focus the attention row.
public struct CloudChatAttention: Equatable, Sendable {
    public enum Kind: String, Sendable { case question, permission, done }
    public let kind: Kind
    public let sessionID: String
    public let machineID: String?
    public let title: String
    public let body: String

    public init(kind: Kind, sessionID: String, machineID: String? = nil, title: String = "Cloud", body: String = "") {
        self.kind = kind; self.sessionID = sessionID; self.machineID = machineID; self.title = title; self.body = body
    }

    /// Parses only the namespaced Cloud keys. Unknown or incomplete pushes
    /// stay on the existing feed responder and cannot open an arbitrary chat.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let rawKind = userInfo["cmux.cloud.kind"] as? String,
              let kind = Kind(rawValue: rawKind),
              let sessionID = userInfo["cmux.cloud.session_id"] as? String,
              !sessionID.isEmpty else { return nil }
        self.init(kind: kind, sessionID: sessionID, machineID: userInfo["cmux.cloud.machine_id"] as? String,
                  title: userInfo["cmux.cloud.title"] as? String ?? "Cloud",
                  body: userInfo["cmux.cloud.body"] as? String ?? "")
    }
}
