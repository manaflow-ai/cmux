import Darwin
import Testing
@testable import CmuxCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Kernel listener sidebar filtering", .serialized)
struct ListeningPortLookupTests {
    @Test("IPv4 loopback dynamic listeners are hidden")
    func loopbackIPv4() throws {
        try checkListener(address: "127.0.0.1", family: AF_INET, visible: false)
    }

    @Test("IPv6 loopback dynamic listeners are hidden")
    func loopbackIPv6() throws {
        try checkListener(address: "::1", family: AF_INET6, visible: false)
    }

    @Test("Mapped IPv4 loopback dynamic listeners are hidden")
    func mappedLoopback() throws {
        try checkListener(address: "::ffff:127.0.0.1", family: AF_INET6, visible: false)
    }

    @Test("Wildcard dynamic listeners remain visible", arguments: [AF_INET, AF_INET6])
    func wildcard(family: Int32) throws {
        try checkListener(address: family == AF_INET ? "0.0.0.0" : "::", family: family, visible: true)
    }

    private func checkListener(address: String, family: Int32, visible: Bool) throws {
        let fd = socket(family, SOCK_STREAM, 0)
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        // Select a free dynamic port explicitly, independent of the machine's
        // ephemeral allocator configuration and of other concurrently run tests.
        var selectedPort: Int?
        for port in 55_000...55_200 {
            let result: Int32
            if family == AF_INET {
                var endpoint = sockaddr_in()
                endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                endpoint.sin_family = sa_family_t(AF_INET)
                endpoint.sin_port = UInt16(port).bigEndian
                #expect(inet_pton(AF_INET, address, &endpoint.sin_addr) == 1)
                result = withUnsafePointer(to: &endpoint) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            } else {
                var endpoint = sockaddr_in6()
                endpoint.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                endpoint.sin6_family = sa_family_t(AF_INET6)
                endpoint.sin6_port = UInt16(port).bigEndian
                #expect(inet_pton(AF_INET6, address, &endpoint.sin6_addr) == 1)
                result = withUnsafePointer(to: &endpoint) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
            }
            if result == 0 {
                selectedPort = port
                break
            }
            if errno != EADDRINUSE { break }
        }
        let port = try #require(selectedPort)
        try #require(listen(fd, 1) == 0)
        let result = ListeningPortLookup.ports(pid: getpid())
        guard case .ports(let ports) = result else {
            Issue.record("Kernel lookup failed: \(result)")
            return
        }
        #expect(ports.contains(port) == visible)
    }
}
