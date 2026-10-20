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

    /// The Macs this phone pinned (first pairing); a Mac that cannot prove its
    /// pinned key is refused `mac_identity_changed`.
    public let pins: MacPins

    public init(keys: PhoneKeys, phoneID: String, name: String, pins: MacPins = .standard) {
        self.keys = keys
        self.phoneID = phoneID
        self.name = name
        self.pins = pins
    }

    /// What the phone says when a paired Mac's identity changed.
    public static let identityChanged = String(localized: """
        This Mac's identity changed, so this iPhone won't connect: it may not be your Mac. \
        If you reinstalled cmux or replaced the Mac, remove it in Settings → Devices, then let it add itself again.
        """)

    /// Where pairing with the linked Mac stands.
    public enum State: Equatable, Sendable {
        case idle
        /// The Mac shows "Allow … to connect?"; the link waits for the answer.
        case waiting(mac: String)
        /// The same, after this phone replaced an unreadable stored key (the
        /// Mac asks again because the key is new).
        case waitingAfterNewKeys(mac: String)
        case paired
        /// The user refused this phone on the Mac.
        case denied(mac: String)
        case failed(String)

        /// The Mac is asking its person about this phone.
        public var isWaiting: Bool {
            switch self {
            case .waiting, .waitingAfterNewKeys: true
            default: false
            }
        }
    }

    /// What the phone says for a refusal `code` from the Mac's `auth`.
    public static func refusalText(_ error: LinkError) -> String {
        switch error.code {
        case "timeout": "nobody answered the Mac's prompt. Retry, then allow this iPhone on the Mac"
        case "rate_limited": "the Mac asked about this iPhone recently: \(error.message)"
        case "busy": "the Mac is already pairing this iPhone"
        case "mac_identity_changed": identityChanged
        case "unavailable": "the Mac isn't ready to pair yet. Retry in a moment"
        default: error.message
        }
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
        /// This phone's nonce for the Mac's identity proof.
        let macNonce: String

        /// Abandons it (the link moved on before the challenge was answered).
        public func close() async { await channel.close(code: "eof", reason: "") }
    }

    /// Opens `auth` on `link`. It costs no round trip, and the Mac holds the
    /// channels the phone opens after it until it passes, so the rest of the
    /// link opens right behind it.
    public func open(link: any MacLink) async -> Result<Opened, LinkError> {
        do {
            let (identity, approval) = try keys.publicKeys()
            let macNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let channel = try await link.openChannel(service: "auth", args: [
                "identityKey": identity, "approvalKey": approval, "name": String(name.prefix(64)), "action": "pair",
                "macNonce": macNonce,
            ])
            return .success(Opened(channel: channel, identity: identity, approval: approval, macNonce: macNonce))
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
        let pinned = pins.key(for: macID)
        /// The key this Mac proved in this `auth`, pinned once the Mac lets this phone in.
        var proven: String?
        do {
            while true {
                guard let frame = try await channel.receive() else {
                    let closed = channel.closedBy ?? LinkError(code: "closed", message: "The Mac closed pairing")
                    // A Mac with no `auth` cannot prove a pinned key either.
                    if closed.code == "unknown_service", pinned != nil { return .refused(Self.changed) }
                    return closed.code == "unknown_service" ? .legacy : .refused(closed)
                }
                let value = try JSONDecoder().decode(JSONValue.self, from: frame)
                if value["ok"] == .bool(true) {
                    if pinned != nil, proven == nil { return .refused(Self.changed) }
                    if pinned == nil, let proven { pins.pin(proven, for: macID) }
                    return .paired(macDevice: macID)
                }
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
                // The Mac's identity key: its proof must hold, and match the pin.
                switch Self.check(value, mac: mac, phone: phoneID, macNonce: opened.macNonce, challenge: nonce, pinned: pinned) {
                case .proven(let key): proven = key
                case .unproven: break
                case .refused(let error): return .refused(error)
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

    static let changed = LinkError(code: "mac_identity_changed", message: identityChanged)

    /// What a challenge says about the Mac's identity.
    enum MacProof: Equatable {
        /// It proved this key.
        case proven(String)
        /// An older Mac that sends no key, and none is pinned.
        case unproven
        case refused(LinkError)
    }

    /// Checks the challenge's `macKey` / `macSignature` against this phone's nonce and the pin.
    static func check(_ value: JSONValue, mac: String, phone: String, macNonce: String, challenge: String,
                      pinned: String?) -> MacProof {
        guard let key = value["macKey"]?.stringValue, let signature = value["macSignature"]?.stringValue else {
            return pinned == nil ? .unproven : .refused(changed)
        }
        let message = MacPins.proofMessage(mac: mac, phone: phone, phoneNonce: macNonce, challenge: challenge)
        guard MacPins.verify(key: key, signature: signature, message: message) else {
            return .refused(pinned == nil ? LinkError(code: "bad_mac_proof", message: "The Mac's identity proof is invalid") : changed)
        }
        if let pinned, pinned != key.lowercased() { return .refused(changed) }
        return .proven(key.lowercased())
    }

    /// "Remove This iPhone from My Macs": asks the Mac to forget this phone (best effort, over a live link).
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
