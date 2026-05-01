import Combine
import Foundation

@MainActor
protocol TerminalWorkspaceMetadataStreaming {
    func metadataPublisher(for identity: TerminalWorkspaceBackendIdentity) -> AnyPublisher<TerminalWorkspaceBackendMetadata, Never>
}

@MainActor
struct NoOpWorkspaceMetadataService: TerminalWorkspaceMetadataStreaming {
    func metadataPublisher(for identity: TerminalWorkspaceBackendIdentity) -> AnyPublisher<TerminalWorkspaceBackendMetadata, Never> {
        Empty().eraseToAnyPublisher()
    }
}
