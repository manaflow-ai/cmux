#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import Observation
import OSLog
import Security

extension NextTransportDialClient {
    /// One fully parsed and validated ticket + grant pair.
    struct ParsedConfiguration {
        var hostKey: Data
        var addrs: [String]
        var relayURL: String?
        var grant: PairingGrant
    }

    static func parseConfiguration(
        ticketJSON: String, grantJSON: String, identity: PeerIdentity
    ) throws -> ParsedConfiguration {
        guard let ticketData = ticketJSON.data(using: .utf8),
            let ticket = (try? JSONDecoder().decode(JSONValue.self, from: ticketData))?
                .objectValue,
            let key = ticket["key"]?.dataValue,
            let addrs = ticket["addrs"]?.arrayValue?.compactMap(\.stringValue)
        else {
            throw NextTransportConfigureError.malformedTicket
        }
        guard let grantData = grantJSON.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: grantData),
            let parsed = PairingGrant(payloadValue: value.objectValue?["grant"] ?? value)
        else {
            throw NextTransportConfigureError.malformedGrant
        }
        guard parsed.devicePublicKey == identity.publicKeyData else {
            throw NextTransportConfigureError.grantKeyMismatch
        }
        guard parsed.deviceID == identity.deviceID else {
            throw NextTransportConfigureError.grantDeviceIDMismatch
        }
        guard parsed.appIdentity == identity.appIdentity else {
            throw NextTransportConfigureError.grantAppMismatch
        }
        return ParsedConfiguration(
            hostKey: key, addrs: addrs,
            relayURL: ticket["relay"]?.stringValue, grant: parsed)
    }

    func commit(_ parsed: ParsedConfiguration) {
        updateHints(parsed)
        dialAttemptIndex = 0
        relayOnlyAttemptFailed = false
        pendingAdmittedSessionID = nil
        sessionID = nil
    }

    /// Refreshes routing material without resetting the reconnect owner's history.
    func updateHints(_ parsed: ParsedConfiguration) {
        hostKey = parsed.hostKey
        hostAddrs = parsed.addrs
        hostRelayURL = parsed.relayURL
        grant = parsed.grant
    }

}
#endif
