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

/// Interprets one `mobile.next_transport.pair` probe failure through the
/// RPC layer's TYPED error (`MobileShellConnectionError.rpcError`), never
/// `String(describing:)`: only a server-reported unknown-method code is a
/// capability verdict; everything else is transient.
struct NextTransportProbeErrorClassifier: Sendable {
    let methodNotFoundCodes: Set<String>

    init(methodNotFoundCodes: Set<String> = [
        "method_not_found", "unknown_method", "unsupported_method",
    ]) {
        self.methodNotFoundCodes = methodNotFoundCodes
    }

    func isMethodNotFound(_ error: any Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        return isMethodNotFound(code: code, message: message)
    }

    func isMethodNotFound(code: String?, message: String) -> Bool {
        if let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            methodNotFoundCodes.contains(code)
        {
            return true
        }
        return false
    }
}
#endif
