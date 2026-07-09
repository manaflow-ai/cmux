import Foundation
@preconcurrency import Network
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
func mobileHostAuthorizationTestByteConnection() -> NWMobileHostByteConnection {
    mobileHostAuthorizationTestByteConnection(
        NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: 9)!,
            using: .tcp
        )
    )
}

@MainActor
func mobileHostAuthorizationTestByteConnection(_ connection: NWConnection) -> NWMobileHostByteConnection {
    NWMobileHostByteConnection(
        connection: connection,
        callbackQueue: DispatchQueue(label: "test.mobile.host-connection")
    )
}
