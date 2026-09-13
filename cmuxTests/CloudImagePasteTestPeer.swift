import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A scripted peer at the mirror's actual command/acknowledgement boundary.
@MainActor
final class CloudImagePasteTestPeer {
    struct Command: Sendable {
        let requestID: UInt64
        let operation: String
        let uploadID: String
        let terminalID: String
        let surfaceID: UInt64
        let lease: String
        let offset: Int?
        let bytes: Data
        let hasPath: Bool
    }
    let coordinator: CloudImagePasteCoordinator
    let commands: AsyncStream<Command>
    private let continuation: AsyncStream<Command>.Continuation
    private(set) var sent: [Command] = []

    init(coordinator: CloudImagePasteCoordinator = CloudImagePasteCoordinator()) {
        self.coordinator = coordinator
        (commands, continuation) = AsyncStream.makeStream(of: Command.self)
    }

    func bind(capabilities: Set<String> = [CloudImagePasteCoordinator.capability], lease: String? = "lease-test") {
        coordinator.bind(terminalID: "term_test", surfaceID: 17, lease: lease, capabilities: capabilities) { [weak self] fields in
            guard let self else { throw CloudImagePasteError.unavailable }
            let id = UInt64(sent.count + 100)
            let command = Command(
                requestID: id, operation: fields["op"] as? String ?? "",
                uploadID: fields["upload_id"] as? String ?? "",
                terminalID: fields["terminal_id"] as? String ?? "",
                surfaceID: fields["surface"] as? UInt64 ?? 0,
                lease: fields["lease"] as? String ?? "", offset: fields["offset"] as? Int,
                bytes: (fields["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data(),
                hasPath: fields["path"] != nil
            )
            sent.append(command)
            continuation.yield(command)
            return id
        }
    }

    func acknowledge(_ command: Command) {
        _ = coordinator.receive(requestID: command.requestID, ok: true, error: nil)
    }
}
