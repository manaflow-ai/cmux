import Foundation
import Testing
import WireGuardTunnelDevice

@Suite("WireGuard device identity")
struct TunnelFileDescriptorTests {
    let ipv4 = Data([100, 64, 0, 1])
    let ipv6 = Data([0xfd, 0x7a, 0x75, 0x70, 0x6c, 0x6b, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])

    @Test("cancelled empty utuns cannot steal traffic from the configured interface")
    func skipsCancelledDevices() {
        let stale = TunnelFileDescriptor(descriptor: 7, interfaceName: "utun28", addresses: [])
        let current = TunnelFileDescriptor(descriptor: 11, interfaceName: "utun33", addresses: [ipv4, ipv6])
        #expect(TunnelFileDescriptor.select(from: [stale, current], matching: [ipv4, ipv6]) == current)
    }

    @Test("an ambiguous interface identity fails instead of choosing by descriptor order")
    func refusesAmbiguousDevices() {
        let one = TunnelFileDescriptor(descriptor: 7, interfaceName: "utun28", addresses: [ipv4, ipv6])
        let two = TunnelFileDescriptor(descriptor: 11, interfaceName: "utun33", addresses: [ipv4, ipv6])
        #expect(TunnelFileDescriptor.select(from: [one, two], matching: [ipv4, ipv6]) == nil)
    }

    @Test("every configured address must be present")
    func refusesPartialConfiguration() {
        let partial = TunnelFileDescriptor(descriptor: 7, interfaceName: "utun28", addresses: [ipv4])
        #expect(TunnelFileDescriptor.select(from: [partial], matching: [ipv4, ipv6]) == nil)
    }

    @Test("duplicated descriptors for one device preserve a unique interface identity")
    func acceptsDuplicateHandles() {
        let one = TunnelFileDescriptor(descriptor: 7, interfaceName: "utun33", addresses: [ipv4, ipv6])
        let duplicate = TunnelFileDescriptor(descriptor: 11, interfaceName: "utun33", addresses: [ipv4, ipv6])
        #expect(TunnelFileDescriptor.select(from: [one, duplicate], matching: [ipv4, ipv6]) == one)
    }

    @Test("an interface-name query excludes empty cancelled devices")
    func diagnosticIdentity() {
        let stale = TunnelFileDescriptor(descriptor: 7, interfaceName: "utun28", addresses: [])
        let current = TunnelFileDescriptor(descriptor: 11, interfaceName: "utun33", addresses: [ipv4, ipv6])
        #expect(TunnelFileDescriptor.select(from: [stale, current], matching: []) == current)
    }
}
