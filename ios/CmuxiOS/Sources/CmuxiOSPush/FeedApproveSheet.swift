public import CmuxFeedPushCore
public import Foundation
public import Observation
public import SwiftUI

/// The phone's answer to an agent's permission request that the person's Mac
/// posted (cx-aocz). The person sees the tool, summary and command first; an
/// allow is signed with the presence key after Face ID, Touch ID or the
/// passcode. A deny needs no proof.
@MainActor
@Observable
public final class FeedApproveModel {
    public enum Phase: Hashable, Sendable {
        case loading
        /// No presence key on this phone yet: set it up first.
        case needsKey
        /// The key is registered; the owner accepts it from this time.
        case coolingDown(until: Date)
        case ready
        case sending
        case sent(allow: Bool)
        /// The request was answered or withdrawn on another device.
        case closed
        case failed(String)
    }

    public let request: FeedApproveRequest
    public var scope: String
    public private(set) var phase: Phase = .loading

    private let signer: any FeedApproveSigning
    private let ops: any CloudOpsSending
    /// Dismisses the sheet.
    public var onDone: (() -> Void)?

    public init(request: FeedApproveRequest, scope: String, signer: any FeedApproveSigning,
                ops: any CloudOpsSending) {
        self.request = request
        self.scope = request.scopes.contains(scope) ? scope : (request.scopes.first ?? "once")
        self.signer = signer
        self.ops = ops
    }

    /// Reads the key state (no Face ID).
    public func load() async {
        guard request.isOpen else {
            phase = .closed
            return
        }
        do {
            phase = Self.phase(try await signer.keyState())
        } catch {
            phase = .failed(String(localized: "approve.keyUnknown", defaultValue: "Could not read this phone's approval key.",
                                   bundle: .module))
        }
    }

    /// Creates and registers the presence key; the cooldown starts now.
    public func enroll() async {
        phase = .loading
        do {
            phase = Self.phase(try await signer.enroll())
        } catch {
            phase = .failed(String(localized: "approve.enrollFailed", defaultValue: "Could not set up the approval key.",
                                   bundle: .module))
        }
    }

    /// Sends the answer: an allow after user presence, signed; a deny plain.
    public func answer(allow: Bool) async {
        if allow, phase != .ready { return }
        phase = .sending
        do {
            let answer: FeedAnswer = allow
                ? try await request.signedAnswer(allow: true, scope: scope, signer: signer)
                : .decision(allow: false, scope: nil)
            let key = "approve:\(request.item):\(allow ? "allow" : "deny"):\(scope)"
            try await ops.send(.answer(item: request.item, answer: answer, idempotencyKey: key))
            phase = .sent(allow: allow)
            onDone?()
        } catch {
            // A cancelled Face ID prompt or a failed send: nothing was answered.
            phase = .failed(String(localized: "approve.notSent", defaultValue: "Not sent. The request is still open.",
                                   bundle: .module))
        }
    }

    /// Back to the key state after a failure.
    public func retry() async {
        await load()
    }

    private static func phase(_ state: FeedApproveKeyState) -> Phase {
        switch state {
        case .missing: .needsKey
        case .coolingDown(let until): .coolingDown(until: until)
        case .ready: .ready
        }
    }
}

/// The sheet for ``FeedApproveModel``.
public struct FeedApproveSheet: View {
    @Bindable var model: FeedApproveModel

    public init(model: FeedApproveModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !model.request.title.isEmpty { Text(model.request.title).font(.headline) }
                    row("approve.tool", model.request.shown.tool)
                    row("approve.summary", model.request.shown.summary)
                    if !model.request.shown.command.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("approve.command", bundle: .module).font(.caption).foregroundStyle(.secondary)
                            Text(model.request.shown.command).font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("approve.signedFooter", bundle: .module)
                }
                if model.request.scopes.count > 1 {
                    Section {
                        Picker(selection: $model.scope) {
                            ForEach(model.request.scopes, id: \.self) { scope in
                                Text(Self.scopeLabel(scope)).tag(scope)
                            }
                        } label: {
                            Text("approve.scope", bundle: .module)
                        }
                    }
                }
                Section { state } footer: { footer }
            }
            .navigationTitle(Text("approve.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { model.onDone?() } label: { Text("approve.close", bundle: .module) }
                }
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private var state: some View {
        switch model.phase {
        case .loading, .sending:
            ProgressView()
        case .needsKey:
            Button { Task { await model.enroll() } } label: { Text("approve.setUp", bundle: .module) }
            denyButton
        case .coolingDown:
            denyButton
        case .ready:
            Button { Task { await model.answer(allow: true) } } label: { Text("approve.allow", bundle: .module) }
            denyButton
        case .sent(let allow):
            Text(allow ? "approve.sentAllow" : "approve.sentDeny", bundle: .module)
        case .closed:
            Text("approve.closed", bundle: .module)
        case .failed:
            Button { Task { await model.retry() } } label: { Text("approve.retry", bundle: .module) }
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.phase {
        case .needsKey:
            Text("approve.needsKeyFooter", bundle: .module)
        case .coolingDown(let until):
            Text(String(localized: "approve.coolingDown", defaultValue: "This phone can approve from {time}. Until then, approve on your Mac.",
                        bundle: .module)
                .replacingOccurrences(of: "{time}", with: until.formatted(date: .abbreviated, time: .shortened)))
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var denyButton: some View {
        Button(role: .destructive) { Task { await model.answer(allow: false) } } label: {
            Text("approve.deny", bundle: .module)
        }
    }

    @ViewBuilder private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        if !value.isEmpty {
            LabeledContent { Text(value) } label: { Text(label, bundle: .module) }
        }
    }

    static func scopeLabel(_ scope: String) -> String {
        switch scope {
        case "session": String(localized: "approve.scope.session", defaultValue: "For this session", bundle: .module)
        default: String(localized: "approve.scope.once", defaultValue: "Once", bundle: .module)
        }
    }
}
