import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A transport that authenticates itself does not fail when it needs a passcode. It prints a prompt
/// and waits. cmux spawns it with pipes, so the prompt has nowhere to go, and the bytes land in the
/// stream ahead of control mode.
///
/// Read as a reachability problem, that attach reported "could not mirror any tmux session" and sent
/// the user to check their network instead of their second factor. Three earlier attempts at this
/// check never fired, each for a reason these tests now pin:
///
/// - the pre-control buffer only filled while reconnecting, so on a first attach it was always empty;
/// - `feed` emits on a newline, so a bare `Passcode: ` sat in the parser and was never delivered;
/// - by the time a caller gave up waiting the connection was already gone, so asking it what happened
///   returned nothing.
@MainActor
struct RemoteTmuxCredentialPromptAttachTests {
    private func brokeredConnection() -> RemoteTmuxControlConnection {
        RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039),
            sessionName: "work"
        )
    }

    /// A first attach, which is the case that was broken: nothing has reconnected, so a check gated on
    /// reconnecting cannot see these bytes.
    @Test func aPromptOnAFirstAttachIsRecognised() {
        let connection = brokeredConnection()
        connection.ingest(Data("(host) two-factor login for someone\n\nEnter a passcode:\n".utf8))
        #expect(
            connection.isAwaitingCredentials,
            "a prompt before control mode on a first attach is a login, not an unreachable host"
        )
    }

    /// The real shape. A prompt is written without a newline precisely because it is waiting to be
    /// answered, and the parser only emits a message when it sees one — so this arrives nowhere unless
    /// the unterminated tail is part of the classification.
    @Test func anUnterminatedPromptIsRecognised() {
        let connection = brokeredConnection()
        connection.ingest(Data("Passcode: ".utf8))
        #expect(
            connection.isAwaitingCredentials,
            "a prompt with no trailing newline is the only shape a real one has"
        )
    }

    /// Ordinary remote noise must not be read as a login. A host that prints a banner and then works
    /// has to attach, and a false positive here would tell the user to log in when nothing asked.
    @Test func ordinaryPreControlNoiseIsNotAPrompt() {
        let connection = brokeredConnection()
        connection.ingest(Data("Last login: Tue Jul 21 09:14:02 2026 from 10.0.0.2\n".utf8))
        #expect(!connection.isAwaitingCredentials)
    }

    /// The region ends at control mode. Pane bytes can contain anything, including the word passcode,
    /// and a mirror that is already working must never be reclassified as needing a login.
    @Test func paneOutputAfterControlModeIsNotAPrompt() {
        let connection = brokeredConnection()
        connection.handle(.enter)
        connection.ingest(Data("%output %1 Password:\r\n".utf8))
        #expect(
            !connection.isAwaitingCredentials,
            "after control mode these are pane bytes, not the transport talking"
        )
    }

    /// What a caller actually sees. `stop()` and a stream `%exit` both discard the connection, so the
    /// reason has to be latched while it still exists — measured, an earlier version read through the
    /// live connection and found it nil every time.
    @Test func theVerdictSurvivesTheConnectionItCameFrom() {
        let view = RemoteTmuxViewConnection(
            host: RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039),
            ownerId: "test-owner"
        )
        #expect(!view.lastStreamAwaitedCredentials)

        view.adoptConnectionForTesting(brokeredConnection())
        view.connection?.ingest(Data("Passcode: ".utf8))
        #expect(view.connection?.isAwaitingCredentials == true)

        view.stop()
        #expect(view.connection == nil, "stop discards the connection, which is the whole problem")
        #expect(
            view.lastStreamAwaitedCredentials,
            "the reason must outlive the connection, or the caller has nothing to report"
        )
    }

    /// A latched verdict must not be erased by a later teardown that has no connection to ask.
    @Test func aSecondTeardownDoesNotEraseTheVerdict() {
        let view = RemoteTmuxViewConnection(
            host: RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039),
            ownerId: "test-owner"
        )
        view.adoptConnectionForTesting(brokeredConnection())
        view.connection?.ingest(Data("Passcode: ".utf8))
        view.stop()
        view.stop()
        #expect(view.lastStreamAwaitedCredentials)
    }

    /// All three places that report "nothing mirrored" route through one function, so they cannot
    /// drift apart. Two of them used to compose the same generic sentence independently.
    @Test func oneClassifierDecidesWhatNothingMirroredMeans() {
        #expect(
            RemoteTmuxController.mirrorFailure(destination: "user@host", awaitingCredentials: true)
                == .authenticationRequired("user@host")
        )
        #expect(
            RemoteTmuxController.mirrorFailure(destination: "user@host", awaitingCredentials: false)
                == .unreachable("could not mirror any tmux session on user@host")
        )
    }

    /// The case the unit tests missed while the product was broken: by the time the attach gives up,
    /// the stream that saw the prompt has ended, and its teardown has already removed the view from the
    /// host map. Latching on the view was not enough — whoever asks has to find the verdict anyway.
    @Test func theVerdictOutlivesTheViewBeingDiscarded() {
        let host = RemoteTmuxHost(destination: "user@host", transport: .et, transportPort: 2039)
        RemoteTmuxController.hostsAwaitingCredentials.remove(host.connectionHash)

        let view = RemoteTmuxViewConnection(host: host, ownerId: "test-owner")
        var noted = false
        view.onAwaitingCredentials = { noted = true }
        view.adoptConnectionForTesting(brokeredConnection())
        view.connection?.ingest(Data("Enter a passcode:\n".utf8))

        // The stream ends and everything holding the reason goes away.
        view.stop()
        #expect(noted, "the verdict has to be published before the view can be discarded")

        RemoteTmuxController.hostsAwaitingCredentials.insert(host.connectionHash)
        #expect(
            RemoteTmuxController.mirrorFailure(
                destination: host.destination,
                awaitingCredentials: RemoteTmuxController.hostsAwaitingCredentials
                    .contains(host.connectionHash)
            ) == .authenticationRequired(host.destination),
            "with no view and no connection left, the host-level note is the only thing that knows"
        )
        RemoteTmuxController.hostsAwaitingCredentials.remove(host.connectionHash)
    }

    /// A flushed line alone is enough. Measured in the product: a prompt arrives as a flushed preamble
    /// plus an unterminated tail, and either one has to classify on its own.
    @Test func aFlushedPreambleClassifiesWithoutTheTail() {
        let connection = brokeredConnection()
        connection.ingest(Data("Enter a passcode:\n".utf8))
        #expect(connection.isAwaitingCredentials)
    }

    /// The message the user reads. "host unreachable" is the wrong classification for a host that
    /// answered and asked for credentials.
    @Test func theErrorNamesTheLoginRatherThanTheNetwork() {
        let message = RemoteTmuxError.authenticationRequired("user@host").message
        #expect(message.contains("user@host"), "the user has to know which host is asking")
        #expect(message.lowercased().contains("credentials"))
        #expect(
            !message.lowercased().contains("unreachable"),
            "the host answered; sending the user to the network is the bug being fixed"
        )
    }
}
