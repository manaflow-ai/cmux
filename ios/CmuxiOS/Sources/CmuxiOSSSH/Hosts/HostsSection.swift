import Foundation

/// The Hosts list sections, in display order.
enum HostsSection: String, CaseIterable, Hashable, Sendable {
    case ssh
    case direct
    case paired

    var title: String {
        switch self {
        case .ssh: SSHText.sshHosts
        case .direct: SSHText.directHosts
        case .paired: SSHText.pairedMacs
        }
    }
}
