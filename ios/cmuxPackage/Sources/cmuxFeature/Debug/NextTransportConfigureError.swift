#if DEBUG
import CmuxAuthRuntime
import CmuxNextTransport
import Foundation
import Observation
import OSLog
import Security


/// Typed rejection from `configure(ticketJSON:grantJSON:)`. The call is
/// atomic: when any of these is thrown, NO state was committed — the
/// previous ticket/grant (if any) remain in effect.
public enum NextTransportConfigureError: Error, Equatable {
    case malformedTicket
    case malformedGrant
    /// Grant minted for a different device key than this phone's identity.
    case grantKeyMismatch
    /// Grant minted for a different durable device ID.
    case grantDeviceIDMismatch
    /// Grant minted for a different app identity.
    case grantAppMismatch
}
#endif
