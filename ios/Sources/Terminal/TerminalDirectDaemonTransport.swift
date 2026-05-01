import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.direct-daemon")

enum TerminalDirectDaemonTransportError: LocalizedError {
    case missingTeamID

    var errorDescription: String? {
        switch self {
        case .missingTeamID:
            return "Direct daemon transport requires a team-scoped server."
        }
    }
}

final class TerminalDirectDaemonTransport: @unchecked Sendable, TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let host: TerminalHost
    private let credentials: TerminalSSHCredentials
    private let sessionName: String
    private let resumeState: TerminalRemoteDaemonResumeState?
    private let ticketService: any TerminalDaemonTicketProviding
    private let directClient: any TerminalDirectDaemonConnecting
    private let sessionTransportFactory: @Sendable (
        any TerminalRemoteDaemonTransport,
        String,
        String,
        TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport
    private let fallbackTransportFactory: @Sendable (
        TerminalHost,
        TerminalSSHCredentials,
        String,
        TerminalRemoteDaemonResumeState?
    ) -> TerminalTransport
    private let stateQueue = DispatchQueue(label: "TerminalDirectDaemonTransport.state")

    private var activeTransport: TerminalTransport?
    private var lastKnownResumeState: TerminalRemoteDaemonResumeState?

    init(
        host: TerminalHost,
        credentials: TerminalSSHCredentials,
        sessionName: String,
        resumeState: TerminalRemoteDaemonResumeState? = nil,
        ticketService: any TerminalDaemonTicketProviding = TerminalDaemonTicketService(),
        directClient: any TerminalDirectDaemonConnecting = TerminalDirectDaemonClient(),
        sessionTransportFactory: @escaping @Sendable (
            any TerminalRemoteDaemonTransport,
            String,
            String,
            TerminalRemoteDaemonResumeState?
        ) -> TerminalTransport = { transport, command, sessionName, resumeState in
            TerminalRemoteDaemonSessionTransport(
                client: TerminalRemoteDaemonClient(transport: transport),
                command: command,
                resumeState: resumeState
            )
        },
        fallbackTransportFactory: @escaping @Sendable (
            TerminalHost,
            TerminalSSHCredentials,
            String,
            TerminalRemoteDaemonResumeState?
        ) -> TerminalTransport = { host, credentials, sessionName, resumeState in
            TerminalRemoteDaemonBootstrapTransport(
                host: host,
                credentials: credentials,
                sessionName: sessionName,
                resumeState: resumeState
            )
        }
    ) {
        self.host = host
        self.credentials = credentials
        self.sessionName = sessionName
        self.resumeState = resumeState
        self.ticketService = ticketService
        self.directClient = directClient
        self.sessionTransportFactory = sessionTransportFactory
        self.fallbackTransportFactory = fallbackTransportFactory
        self.lastKnownResumeState = resumeState
    }

    func connect(initialSize: TerminalGridSize) async throws {
        log.debug("connect: hostname=\(self.host.hostname, privacy: .public) teamID=\(self.host.teamID ?? "nil", privacy: .public) shouldBootstrapDirectly=\(self.shouldUseBootstrapTransportDirectly, privacy: .public) sshAuthMethod=\(String(describing: self.host.sshAuthenticationMethod), privacy: .public) hasCredential=\(self.credentials.hasCredential(for: self.host.sshAuthenticationMethod), privacy: .public)")
        if shouldUseBootstrapTransportDirectly {
            log.debug("connect: → bootstrap transport directly (no teamID or has SSH creds)")
            let bootstrapTransport = fallbackTransportFactory(host, credentials, sessionName, resumeState)
            try await connect(
                transport: bootstrapTransport,
                initialSize: initialSize
            )
            return
        }

        do {
            log.debug("connect: → trying direct daemon ticket")
            let transport = try await makeDirectTransport()
            try await connect(
                transport: transport,
                initialSize: initialSize
            )
        } catch {
            log.error("connect: direct failed: \(error.localizedDescription, privacy: .public)")
            if shouldFallback(after: error) {
                eventHandler?(
                    .notice(
                        String(
                            localized: "terminal.workspace.notice.fallback_ssh",
                            defaultValue: "Direct daemon unavailable, using SSH."
                        )
                    )
                )
                let fallbackTransport = fallbackTransportFactory(host, credentials, sessionName, resumeState)
                try await connect(
                    transport: fallbackTransport,
                    initialSize: initialSize
                )
                return
            }
            clearActiveTransport()
            throw error
        }
    }

    private var shouldUseBootstrapTransportDirectly: Bool {
        let normalizedTeamID = host.teamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTeamID?.isEmpty != false else { return false }
        return credentials.hasCredential(for: host.sshAuthenticationMethod)
    }

    func send(_ data: Data) async throws {
        guard let transport = activeTransportSnapshot() else { return }
        try await transport.send(data)
    }

    func resize(_ size: TerminalGridSize) async {
        guard let transport = activeTransportSnapshot() else { return }
        await transport.resize(size)
    }

    func disconnect() async {
        let transport = clearActiveTransport()
        await transport?.disconnect()
        setLastKnownResumeState(nil)
    }

    func suspendPreservingSession() async {
        let transport = clearActiveTransport()
        if let parkingTransport = transport as? TerminalSessionParking {
            await parkingTransport.suspendPreservingSession()
        } else {
            await transport?.disconnect()
            setLastKnownResumeState(nil)
        }
    }

    private func makeDirectTransport() async throws -> TerminalTransport {
        guard let teamID = host.teamID, !teamID.isEmpty else {
            throw TerminalDirectDaemonTransportError.missingTeamID
        }

        let request = TerminalDaemonTicketRequest(
            serverID: host.effectiveServerID,
            teamID: teamID,
            sessionID: resumeState?.sessionID,
            attachmentID: resumeState?.attachmentID,
            capabilities: requestedCapabilities()
        )
        let (ticket, daemonTransport) = try await connectDirectClient(request: request)
        let normalizedResumeState = normalizedResumeState(from: ticket)
        let transport = sessionTransportFactory(
            daemonTransport,
            host.bootstrapCommand.replacingOccurrences(of: "{{session}}", with: sessionName),
            sessionName,
            normalizedResumeState
        )
        transport.eventHandler = { [weak self, weak transport] event in
            self?.handle(event: event, activeTransport: transport)
        }
        return transport
    }

    private func connectDirectClient(
        request: TerminalDaemonTicketRequest
    ) async throws -> (TerminalDaemonTicket, any TerminalRemoteDaemonTransport) {
        log.debug("connectClient: fetching ticket for serverID=\(request.serverID, privacy: .public) teamID=\(request.teamID ?? "nil", privacy: .public)")
        let ticket = try await ticketService.fetchTicket(request: request)
        log.debug("connectClient: got ticket, directURL=\(ticket.directURL, privacy: .public)")
        let certificatePins = normalizedCertificatePins(from: ticket)
        do {
            let daemonTransport = try await directClient.connect(
                url: ticket.directURL,
                ticket: ticket.ticket,
                certificatePins: certificatePins
            )
            return (ticket, daemonTransport)
        } catch let error as TerminalDirectDaemonClientError {
            guard shouldInvalidateCachedTicket(after: error) else {
                throw error
            }

            ticketService.invalidateTicket(request: request)
            let freshTicket = try await ticketService.fetchTicket(request: request)
            let freshCertificatePins = normalizedCertificatePins(from: freshTicket)
            let daemonTransport = try await directClient.connect(
                url: freshTicket.directURL,
                ticket: freshTicket.ticket,
                certificatePins: freshCertificatePins
            )
            return (freshTicket, daemonTransport)
        }
    }

    private func connect(
        transport: TerminalTransport,
        initialSize: TerminalGridSize
    ) async throws {
        transport.eventHandler = { [weak self, weak transport] event in
            self?.handle(event: event, activeTransport: transport)
        }
        setActiveTransport(transport)

        do {
            try await transport.connect(initialSize: initialSize)
        } catch {
            clearActiveTransport(matching: transport)
            throw error
        }
    }

    private func handle(event: TerminalTransportEvent, activeTransport: TerminalTransport?) {
        if let snapshotting = activeTransport as? TerminalRemoteDaemonResumeStateSnapshotting {
            setLastKnownResumeState(snapshotting.remoteDaemonResumeStateSnapshot())
        }
        if case .disconnected = event {
            _ = clearActiveTransport(matching: activeTransport)
        }
        eventHandler?(event)
    }

    private func shouldFallback(after error: Error) -> Bool {
        guard host.allowsSSHFallback else { return false }
        guard credentials.hasCredential(for: host.sshAuthenticationMethod) else { return false }

        switch error {
        case TerminalDirectDaemonTransportError.missingTeamID:
            return true
        case let error as TerminalDirectDaemonClientError:
            if case .connectionFailed = error {
                return true
            }
            return false
        case let error as TerminalDaemonTicketServiceError:
            switch error {
            case .invalidResponse:
                return false
            case .httpError(let statusCode, _):
                return statusCode == 404 || statusCode == 405 || statusCode >= 500
            }
        case is URLError:
            return true
        default:
            return false
        }
    }

    private func shouldInvalidateCachedTicket(after error: TerminalDirectDaemonClientError) -> Bool {
        switch error {
        case .handshakeRejected(let code, _):
            return code == "unauthorized" || code == "forbidden"
        default:
            return false
        }
    }

    private func setActiveTransport(_ transport: TerminalTransport) {
        stateQueue.sync {
            activeTransport = transport
        }
    }

    private func activeTransportSnapshot() -> TerminalTransport? {
        stateQueue.sync { activeTransport }
    }

    private func setLastKnownResumeState(_ state: TerminalRemoteDaemonResumeState?) {
        stateQueue.sync {
            lastKnownResumeState = state
        }
    }

    @discardableResult
    private func clearActiveTransport(matching expectedTransport: TerminalTransport? = nil) -> TerminalTransport? {
        stateQueue.sync {
            if let expectedTransport,
               let activeTransport,
               ObjectIdentifier(activeTransport) != ObjectIdentifier(expectedTransport) {
                return nil
            }
            let transport = activeTransport
            activeTransport = nil
            return transport
        }
    }

    private func normalizedResumeState(from ticket: TerminalDaemonTicket) -> TerminalRemoteDaemonResumeState? {
        guard resumeState != nil else { return nil }
        return TerminalRemoteDaemonResumeState(
            sessionID: ticket.sessionID,
            attachmentID: ticket.attachmentID,
            readOffset: 0
        )
    }

    private func requestedCapabilities() -> [String] {
        if resumeState == nil {
            return ["session.open"]
        }
        return ["session.open", "session.attach"]
    }

    private func normalizedCertificatePins(from ticket: TerminalDaemonTicket) -> [String] {
        let normalizedTicketPins = ticket.directTLSPins.normalizedTerminalPins
        if !normalizedTicketPins.isEmpty {
            return normalizedTicketPins
        }
        return host.directTLSPins
    }
}

extension TerminalDirectDaemonTransport: TerminalRemoteDaemonResumeStateSnapshotting {
    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        stateQueue.sync { lastKnownResumeState }
    }
}

extension TerminalDirectDaemonTransport: TerminalSessionParking {}
