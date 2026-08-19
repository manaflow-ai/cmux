import Foundation
import IrohLib

/// Owns one lazily-bound native Iroh endpoint for the cmux-lite client.
///
/// Binding is shared by concurrent callers. The provider never creates a
/// second endpoint generation merely because two sessions begin at once, and
/// `close()` is explicit so endpoint teardown has a deterministic owner.
public actor IrohLibConnectionProvider: IrohConnectionProvider {
    private let configuration: IrohLibConfiguration
    private let factory: any IrohEndpointFactory
    private var endpoint: (any IrohEndpointDriver)?
    private var isBinding = false
    private var bindingWaiters: [
        CheckedContinuation<any IrohEndpointDriver, any Error>
    ] = []
    private var isClosed = false

    /// Creates a provider using the checked-in IrohLib implementation.
    public init(
        configuration: IrohLibConfiguration = .standard
    ) {
        self.init(
            configuration: configuration,
            factory: IrohLibEndpointFactory()
        )
    }

    /// Test and alternate-runtime initializer.
    init(
        configuration: IrohLibConfiguration,
        factory: any IrohEndpointFactory
    ) {
        self.configuration = configuration
        self.factory = factory
    }

    /// Opens one route through the shared endpoint generation.
    public func connect(to route: IrohRoute) async throws -> any IrohConnection {
        guard !isClosed else {
            throw IrohOpenFailure.closed
        }

        let endpoint = try await endpointDriver()
        do {
            return try await endpoint.connect(
                to: route,
                alpn: configuration.alpn
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as IrohOpenFailure {
            throw failure
        } catch {
            throw IrohLibFailureMapper.openFailure(for: error)
        }
    }

    /// Closes the endpoint generation after all callers have stopped using it.
    public func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        resumeBindingWaiters(throwing: IrohOpenFailure.closed)

        guard let endpoint else {
            return
        }
        self.endpoint = nil
        await endpoint.close()
    }

    private func endpointDriver() async throws -> any IrohEndpointDriver {
        if let endpoint {
            return endpoint
        }
        guard !isClosed else {
            throw IrohOpenFailure.closed
        }

        if isBinding {
            return try await withCheckedThrowingContinuation { continuation in
                bindingWaiters.append(continuation)
            }
        }
        isBinding = true

        do {
            let endpoint = try await factory.bind(configuration: configuration)
            isBinding = false
            guard !isClosed else {
                await endpoint.close()
                resumeBindingWaiters(throwing: IrohOpenFailure.closed)
                throw IrohOpenFailure.closed
            }
            self.endpoint = endpoint
            resumeBindingWaiters(returning: endpoint)
            return endpoint
        } catch is CancellationError {
            isBinding = false
            resumeBindingWaiters(throwing: CancellationError())
            throw CancellationError()
        } catch {
            isBinding = false
            let failure = IrohLibFailureMapper.openFailure(for: error)
            resumeBindingWaiters(throwing: failure)
            throw failure
        }
    }

    private func resumeBindingWaiters(
        returning endpoint: any IrohEndpointDriver
    ) {
        let waiters = bindingWaiters
        bindingWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: endpoint)
        }
    }

    private func resumeBindingWaiters(throwing error: any Error) {
        let waiters = bindingWaiters
        bindingWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }
}

/// Maps the generated binding's coarse error taxonomy into the transport seam.
enum IrohLibFailureMapper {
    static func openFailure(for error: any Error) -> IrohOpenFailure {
        if let failure = error as? IrohOpenFailure {
            return failure
        }
        guard let error = error as? IrohError else {
            return .unavailable
        }
        return openFailure(for: error.kind())
    }

    static func openFailure(for kind: IrohErrorKind) -> IrohOpenFailure {
        switch kind {
        case .invalidInput, .keyParsing, .ticketParsing:
            return .invalidRoute
        case .alpn:
            return .incompatiblePeer
        case .closed:
            return .closed
        case .bind, .connect, .connection, .relay, .stream, .datagram,
             .callback, .timeout, .internal:
            return .unavailable
        }
    }
}
