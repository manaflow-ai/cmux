import CNBackend
import CNCore
import CNMockHost
import CNTransport
import Foundation
import Observation

/// Root app state: which shell to show, the backend session, the paired Macs
/// and the connection to the selected one.
@MainActor
@Observable
public final class AppModel {
    public enum Shell: String, Sendable { case drawer, tabs }

    public let shell: Shell
    public let devScreen: DevScreen?
    public let isMock: Bool
    public let connection: HostConnection
    @ObservationIgnored public let mockHost: MockHost?

    init(shell: Shell, devScreen: DevScreen?, connection: HostConnection, mockHost: MockHost?) {
        self.shell = shell
        self.devScreen = devScreen
        self.isMock = mockHost != nil
        self.connection = connection
        self.mockHost = mockHost
    }

    static func clientInfo(bundle: Bundle) -> ClientInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return ClientInfo(name: "cmux-next-ios", version: version, platform: "ios")
    }

    public static func live(bundle: Bundle) -> AppModel {
        let raw = bundle.object(forInfoDictionaryKey: "CmuxNextShell") as? String
        let shell = Shell(rawValue: raw ?? "") ?? .tabs
        let mock = MockHost()
        let connection = HostConnection(connector: mock.makeConnector(), clientInfo: clientInfo(bundle: bundle))
        connection.connect(hostId: mock.options.hostId)
        return AppModel(shell: shell, devScreen: DevScreen.current(), connection: connection, mockHost: mock)
    }
}
