import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileRPC
import Foundation

public enum MobileIrohTerminalSceneLaneError: Error, Equatable, Sendable {
    case closed
    case emptyInput
    case truncatedEnvelope
    case invalidSurfaceID
}

/// iOS owner for one full-first, independently cancellable semantic-scene lane.
public actor MobileIrohTerminalSceneLane: MobileTerminalSceneConnection {
    public static let maximumInputByteCount = 16 * 1_024

    private let stream: CmxIrohBidirectionalStream
    private var decoder = CmxIrohTerminalSceneEnvelopeDecoder()
    private var validator: CmxIrohTerminalSceneStreamValidator
    private var pendingEnvelopes: [CmxIrohTerminalSceneEnvelope] = []
    private var closed = false

    init(
        stream: CmxIrohBidirectionalStream,
        presentationID: UUID,
        presentationGeneration: UInt64
    ) {
        self.stream = stream
        validator = CmxIrohTerminalSceneStreamValidator(
            presentationID: presentationID,
            presentationGeneration: presentationGeneration
        )
    }

    public func receiveEnvelope() async throws -> MobileTerminalSceneEnvelope? {
        while pendingEnvelopes.isEmpty {
            guard !closed else { return nil }
            guard let bytes = try await stream.receiveStream.receive(
                maximumByteCount: 64 * 1_024
            ) else {
                do {
                    try decoder.finish()
                } catch {
                    throw MobileIrohTerminalSceneLaneError.truncatedEnvelope
                }
                return nil
            }
            pendingEnvelopes.append(contentsOf: try decoder.append(bytes))
        }

        let envelope = pendingEnvelopes.removeFirst()
        try validator.accept(envelope)
        return Self.mobileEnvelope(envelope)
    }

    public func sendInput(_ bytes: Data) async throws {
        guard !closed else { throw MobileIrohTerminalSceneLaneError.closed }
        guard !bytes.isEmpty else { throw MobileIrohTerminalSceneLaneError.emptyInput }
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + Self.maximumInputByteCount)
            let payload = bytes.subdata(in: offset ..< end)
            var length = UInt32(payload.count).bigEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }
            frame.append(payload)
            try await stream.sendStream.send(frame)
            offset = end
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        await stream.sendStream.reset(errorCode: 0)
        await stream.receiveStream.stop(errorCode: 0)
    }

    private static func mobileEnvelope(
        _ envelope: CmxIrohTerminalSceneEnvelope
    ) -> MobileTerminalSceneEnvelope {
        switch envelope {
        case let .configuration(configuration):
            return .configuration(MobileTerminalSceneConfiguration(
                terminalID: configuration.terminalID,
                terminalEpoch: configuration.terminalEpoch,
                presentationID: configuration.presentationID,
                presentationGeneration: configuration.presentationGeneration,
                rendererConfigRevision: configuration.rendererConfigRevision,
                width: configuration.width,
                height: configuration.height,
                contentScale: configuration.contentScale,
                rendererConfig: configuration.rendererConfig
            ))
        case let .scene(scene):
            let kind: MobileTerminalSceneFrame.Kind = switch scene.kind {
            case .full: .full
            case .delta: .delta
            case .unchanged: .unchanged
            }
            return .scene(MobileTerminalSceneFrame(
                terminalID: scene.terminalID,
                terminalEpoch: scene.terminalEpoch,
                contentSequence: scene.contentSequence,
                presentationID: scene.presentationID,
                presentationGeneration: scene.presentationGeneration,
                presentationSequence: scene.presentationSequence,
                kind: kind,
                payload: scene.payload
            ))
        case let .accessibility(accessibility):
            return .accessibility(MobileTerminalSceneAccessibility(
                terminalID: accessibility.terminalID,
                terminalEpoch: accessibility.terminalEpoch,
                contentSequence: accessibility.contentSequence,
                presentationID: accessibility.presentationID,
                presentationGeneration: accessibility.presentationGeneration,
                presentationSequence: accessibility.presentationSequence,
                columns: Int(accessibility.columns),
                rows: Int(accessibility.rows),
                text: accessibility.text
            ))
        }
    }
}
