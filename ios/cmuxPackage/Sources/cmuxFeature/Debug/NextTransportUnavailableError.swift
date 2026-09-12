#if DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import CmuxMobileShell
import CmuxNextTransport
import CmuxNextTransportBridge
import Foundation
import OSLog
import Security

/// Thrown for requests to a next-transport Mac while its session is down:
/// the app fails and reconnects rather than silently degrading to legacy.
struct NextTransportUnavailableError: Error {}
#endif
