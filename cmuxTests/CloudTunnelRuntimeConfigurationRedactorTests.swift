import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The runtime configuration the extension hands the app must carry peers and
/// counters but never key material.
@Suite
struct CloudTunnelRuntimeConfigurationRedactorTests {
    private let redactor = CloudTunnelRuntimeConfigurationRedactor()

    @Test("private and pre-shared keys are dropped; everything else stays in order")
    func redactsKeys() {
        let dump = """
        private_key=0000000000000000000000000000000000000000000000000000000000000001
        listen_port=51820
        public_key=aaaa
        preshared_key=bbbb
        endpoint=203.0.113.9:51820
        last_handshake_time_sec=1700000000
        rx_bytes=10
        tx_bytes=20
        """
        let redacted = redactor.redacted(dump)
        #expect(!redacted.contains("private_key"))
        #expect(!redacted.contains("preshared_key"))
        #expect(redacted == """
        listen_port=51820
        public_key=aaaa
        endpoint=203.0.113.9:51820
        last_handshake_time_sec=1700000000
        rx_bytes=10
        tx_bytes=20
        """)
    }

    @Test("lines without a key=value shape are preserved")
    func keepsUnstructuredLines() {
        #expect(redactor.redacted("errno=0\n\n") == "errno=0\n\n")
    }
}
