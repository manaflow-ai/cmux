import Darwin

/// A numeric IP socket address used for a required Iroh UDP bind.
public struct CmxIrohBindAddress: Equatable, Sendable {
    /// The unbracketed IPv4 or IPv6 literal.
    public let ipAddress: String

    /// The stable, nonzero UDP port.
    public let port: UInt16

    let socketAddress: String

    /// Creates a validated stable bind address.
    ///
    /// Host names and scoped IPv6 literals are intentionally unsupported because
    /// the Iroh FFI parses this value as Rust's numeric `SocketAddr`.
    ///
    /// - Parameters:
    ///   - ipAddress: An unbracketed numeric IPv4 or IPv6 literal.
    ///   - port: A nonzero UDP port.
    /// - Throws: ``CmxIrohBindAddressError`` for unsupported input.
    public init(
        ipAddress: String,
        port: UInt16
    ) throws {
        guard port != 0 else {
            throw CmxIrohBindAddressError.zeroPort
        }
        let bytes = Array(ipAddress.utf8)
        guard (1 ... 64).contains(bytes.count),
              bytes.allSatisfy({ byte in
                  (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
                      || (UInt8(ascii: "A") ... UInt8(ascii: "F")).contains(byte)
                      || byte == UInt8(ascii: ".")
                      || byte == UInt8(ascii: ":")
              })
        else {
            throw CmxIrohBindAddressError.invalidIPAddress
        }

        var ipv4 = in_addr()
        let isIPv4 = ipAddress.withCString {
            inet_pton(AF_INET, $0, &ipv4) == 1
        }
        if isIPv4 {
            self.ipAddress = ipAddress
            self.port = port
            socketAddress = "\(ipAddress):\(port)"
            return
        }

        var ipv6 = in6_addr()
        let isIPv6 = ipAddress.withCString {
            inet_pton(AF_INET6, $0, &ipv6) == 1
        }
        guard isIPv6 else {
            throw CmxIrohBindAddressError.invalidIPAddress
        }
        self.ipAddress = ipAddress
        self.port = port
        socketAddress = "[\(ipAddress)]:\(port)"
    }
}
