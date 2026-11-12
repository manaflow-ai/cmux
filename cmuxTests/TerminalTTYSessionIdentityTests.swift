import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct TerminalTTYSessionIdentityTests {
    @Test("rejects non-terminal device names without opening them")
    func rejectsNonTerminalDevice() {
        #expect(TerminalTTYSessionIdentity.sessionLeaderPID(forDeviceNamed: "null") == nil)
    }

    @Test("rejects malformed device names")
    func rejectsMalformedDeviceName() {
        #expect(TerminalTTYSessionIdentity.sessionLeaderPID(forDeviceNamed: "") == nil)
        #expect(TerminalTTYSessionIdentity(ttyName: "not a tty") == nil)
    }
}
