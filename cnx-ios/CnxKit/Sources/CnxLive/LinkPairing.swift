import CnxAgentChat
import CnxTransport
import Foundation

/// The first channel of every link (cnx-hostd `pairing.rs`, verify/phone-approvals.md):
/// the phone proves its identity key; the Mac serves the link only when the
/// user allowed this phone there, and asks them the first time.
public struct LinkPairing: Sendable {
    public let keys: PhoneKeys
    /// The phone's link device id (the backend stamps it on every signal).
    public let phoneID: String
    /// What the Mac's prompt calls this phone.
    public let name: String

    public init(keys: PhoneKeys, phoneID: String, name: String) {
        self.keys = keys
        self.phoneID = phoneID
        self.name = name
    }

    /// Where pairing with the linked Mac stands.
    public enum State: Equatable, Sendable {
        case idle
        /// The Mac shows "Allow … to connect?"; the link waits for the answer.
        case waiting(mac: String)
        case paired
        /// The user refused this phone on the Mac.
        case denied(mac: String)
        case failed(String)
    }

    /// What pairing found.
    public enum Outcome: Equatable, Sendable {
        /// Paired: this Mac's device id, for approvals.
        case paired(macDevice: String)
        /// An older Mac without pairing: links work as before, Allow stays on the Mac.
        case legacy
        case refused(LinkError)
    }

    /// An `auth` channel this phone opened, before its challenge is answered.
    public struct Opened: Sendable {
        let channel: any LinkChannel
        let identity: String
        let approval: String

        /// Abandons it (the link moved on before the challenge was answered).
        public func close() async { await channel.close(code: "eof", reason: "") }
    }

    /// Opens `auth` on `link`. It costs no round trip, and the Mac holds the
    /// channels the phone opens after it until it passes, so the rest of the
    /// link opens right behind it.
    public func open(link: any MacLink) async -> Result<Opened, LinkError> {
        do {
            let (identity, approval) = try keys.publicKeys()
            let channel = try await link.openChannel(service: "auth", args: [
                "identityKey": identity, "approvalKey": approval, "name": String(name.prefix(64)), "action": "pair",
            ])
            return .success(Opened(channel: channel, identity: identity, approval: approval))
        } catch let error as LinkError {
            return .failure(error)
        } catch {
            return .failure(LinkError(code: "pairing", message: String(describing: error)))
        }
    }

    /// Runs `auth` on `link`. `onWaiting` fires once if the Mac has to ask the user.
    public func run(link: any MacLink, macID: String, onWaiting: @MainActor @Sendable () -> Void) async -> Outcome {
        await finish(await open(link: link), macID: macID, onWaiting: onWaiting)
    }

    /// Answers the challenge on an `auth` channel from ``open(link:)``.
    public func finish(_ auth: Result<Opened, LinkError>, macID: String,
                       onWaiting: @MainActor @Sendable () -> Void) async -> Outcome {
        let opened: Opened
        switch auth {
        case .success(let value): opened = value
        case .failure(let error): return .refused(error)
        }
        let (channel, identity, approval) = (opened.channel, opened.identity, opened.approval)
        defer { Task { await channel.close(code: "eof", reason: "") } }
        do {
            while true {
                guard let frame = try await channel.receive() else {
                    let closed = channel.closedBy ?? LinkError(code: "closed", message: "The Mac closed pairing")
                    return closed.code == "unknown_service" ? .legacy : .refused(closed)
                }
                let value = try JSONDecoder().decode(JSONValue.self, from: frame)
                if value["ok"] == .bool(true) { return .paired(macDevice: macID) }
                if value["pending"] == .bool(true) {
                    await onWaiting()
                    continue
                }
                guard let nonce = value["challenge"]?.stringValue, let mac = value["mac"]?.stringValue else {
                    return .refused(LinkError(code: "bad_request", message: "The Mac sent an unknown pairing step"))
                }
                // The challenge names the Mac this phone dialed, or it signs nothing.
                guard mac == macID else {
                    return .refused(LinkError(code: "wrong_mac", message: "The Mac answered with another device id"))
                }
                let payload = LinkAuthPayload(mac: mac, phone: phoneID, nonce: nonce, identityKey: identity,
                                              approvalKey: approval, action: "pair")
                let signature = try keys.signIdentity(payload.message)
                let reply = try JSONEncoder().encode(JSONValue.object(["signature": .string(ApprovalPayload.hex(signature))]))
                try await channel.send(reply)
            }
        } catch let error as LinkError {
            return .refused(error)
        } catch {
            return .refused(LinkError(code: "pairing", message: String(describing: error)))
        }
    }

    /// Sign-out: asks the Mac to forget this phone (best effort, over a live link).
    public func unpair(link: any MacLink, macID: String) async {
        guard let (identity, approval) = try? keys.publicKeys(),
              let channel = try? await link.openChannel(service: "auth", args: [
                  "identityKey": identity, "approvalKey": approval, "name": "", "action": "unpair",
              ]) else { return }
        defer { Task { await channel.close(code: "eof", reason: "") } }
        guard let frame = try? await channel.receive(), let value = try? JSONDecoder().decode(JSONValue.self, from: frame),
              let nonce = value["challenge"]?.stringValue, value["mac"]?.stringValue == macID else { return }
        let payload = LinkAuthPayload(mac: macID, phone: phoneID, nonce: nonce, identityKey: identity,
                                      approvalKey: approval, action: "unpair")
        guard let signature = try? keys.signIdentity(payload.message),
              let reply = try? JSONEncoder().encode(JSONValue.object(["signature": .string(ApprovalPayload.hex(signature))]))
        else { return }
        try? await channel.send(reply)
        _ = try? await channel.receive()
    }
}
