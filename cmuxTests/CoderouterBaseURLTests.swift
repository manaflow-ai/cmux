import Darwin
import XCTest

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

final class CoderouterBaseURLTests: XCTestCase {
    func testGatewayBaseURLEnvironmentOverrideCanonicalizesLoopback() {
        let previousGateway = getenv("CMUX_CODEROUTER_GATEWAY_BASE_URL").map { String(cString: $0) }
        defer {
            if let previousGateway {
                setenv("CMUX_CODEROUTER_GATEWAY_BASE_URL", previousGateway, 1)
            } else {
                unsetenv("CMUX_CODEROUTER_GATEWAY_BASE_URL")
            }
        }

        setenv("CMUX_CODEROUTER_GATEWAY_BASE_URL", "http://127.0.0.1:3999", 1)

        XCTAssertEqual(AuthEnvironment.coderouterGatewayBaseURL.absoluteString, "http://localhost:3999")
    }

    func testControlPlaneBaseURLEnvironmentOverrideCanonicalizesLoopback() {
        let previousBase = getenv("CMUX_CODEROUTER_BASE_URL").map { String(cString: $0) }
        defer {
            if let previousBase {
                setenv("CMUX_CODEROUTER_BASE_URL", previousBase, 1)
            } else {
                unsetenv("CMUX_CODEROUTER_BASE_URL")
            }
        }

        setenv("CMUX_CODEROUTER_BASE_URL", "http://0.0.0.0:4888", 1)

        XCTAssertEqual(AuthEnvironment.coderouterBaseURL.absoluteString, "http://localhost:4888")
    }
}
