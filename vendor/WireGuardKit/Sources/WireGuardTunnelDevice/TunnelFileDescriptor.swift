import Darwin
import Foundation
import WireGuardKitC

/// An open utun device in this process and the addresses macOS assigned to it.
public struct TunnelFileDescriptor: Equatable, Sendable {
    public let descriptor: Int32
    public let interfaceName: String
    public let addresses: Set<Data>

    /// Captures a device identity without taking ownership of its descriptor.
    public init(descriptor: Int32, interfaceName: String, addresses: Set<Data>) {
        self.descriptor = descriptor
        self.interfaceName = interfaceName
        self.addresses = addresses
    }

    /// Selects the unique configured interface, ignoring empty cancelled devices.
    /// Duplicate handles for one interface are safe; multiple matching interfaces
    /// are ambiguous and fail closed rather than sending packets to an old tunnel.
    public static func select(from candidates: [Self], matching expected: Set<Data>) -> Self? {
        let matches = candidates.filter {
            !$0.addresses.isEmpty && expected.isSubset(of: $0.addresses)
        }
        guard let first = matches.first,
              matches.allSatisfy({ $0.interfaceName == first.interfaceName }) else { return nil }
        return first
    }

    /// Finds a process-owned utun after NetworkExtension applies network settings.
    public static func find(matching expected: Set<Data> = []) -> Self? {
        let addresses = interfaceAddresses()
        var control = WireGuardKitC.ctl_info()
        withUnsafeMutablePointer(to: &control.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        var candidates: [Self] = []
        for descriptor: Int32 in 0...1024 {
            var address = WireGuardKitC.sockaddr_ctl()
            var length = socklen_t(MemoryLayout<WireGuardKitC.sockaddr_ctl>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getpeername(descriptor, $0, &length)
                }
            }
            guard result == 0, address.sc_family == AF_SYSTEM else { continue }
            if control.ctl_id == 0, ioctl(descriptor, CTLIOCGINFO, &control) != 0 { continue }
            guard address.sc_id == control.ctl_id else { continue }
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var nameLength = socklen_t(name.count)
            guard getsockopt(descriptor, 2, 2, &name, &nameLength) == 0 else { continue }
            let interfaceName = String(cString: name)
            candidates.append(Self(descriptor: descriptor, interfaceName: interfaceName,
                                   addresses: addresses[interfaceName, default: []]))
        }
        return select(from: candidates, matching: expected)
    }

    private static func interfaceAddresses() -> [String: Set<Data>] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [:] }
        defer { freeifaddrs(first) }
        var result: [String: Set<Data>] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let bytes: Data
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    var value = $0.pointee.sin_addr
                    return Data(bytes: &value, count: MemoryLayout<in_addr>.size)
                }
            case AF_INET6:
                bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    var value = $0.pointee.sin6_addr
                    return Data(bytes: &value, count: MemoryLayout<in6_addr>.size)
                }
            default: continue
            }
            result[String(cString: entry.pointee.ifa_name), default: []].insert(bytes)
        }
        return result
    }
}
