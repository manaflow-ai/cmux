import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pins the socket error code every recorder failure comes back as.
///
/// A CLI, a dogfood tour and an agent all branch on the code rather than the
/// message: `conflict` means "stop the other recording and retry", `not_found`
/// means "pick another window", `invalid_params` means "fix your flags" and
/// `internal_error` means "this is cmux's fault". Getting one wrong sends a
/// caller down the wrong path, and a case added without a mapping here reads as
/// an internal error even when the caller could fix it.
@Suite struct WindowRecordingErrorCodeTests {
    @Test func registryFailuresSeparateConflictFromNotFound() {
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingRegistry.Failure.busy("abc")) == "conflict")
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingRegistry.Failure.noRecording) == "not_found")
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingRegistry.Failure.unknownRecording("abc")
            ) == "not_found"
        )
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingRegistry.Failure.alreadyStopped("abc")
            ) == "not_found"
        )
    }

    @Test func sessionFailuresReportWhoseFaultTheyAre() {
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingSessionError.unsupportedSystem) == "unsupported")
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingSessionError.windowGone) == "not_found")
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingSessionError.captureTimedOut) == "timeout")
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingSessionError.composeFailed) == "internal_error")
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingSessionError.alreadyFinished) == "internal_error")
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingSessionError.captureFailed("no window server")
            ) == "internal_error"
        )
    }

    /// Opening the output is the caller's parameter; a frame that will not
    /// encode is ours. `record start` creates the file before it answers, so an
    /// `--out` under a read-only volume fails here, and an agent told to fix its
    /// flags on `invalid_params` would retry forever on `internal_error`.
    @Test func writerFailuresSeparateSetupFromEncoding() {
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingWriterError.setup("could not create the gif at /clip.gif")
            ) == "invalid_params"
        )
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingWriterError.frame("the writer rejected a frame")
            ) == "internal_error"
        )
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingWriterError.finish("the writer did not complete")
            ) == "internal_error"
        )
        #expect(
            TerminalController.recordingErrorCode(for: WindowRecordingWriterError.noFrames) == "internal_error"
        )
    }

    /// The case the router's switch was missing: a caller who points `--out` at
    /// a directory gets told their parameter is wrong, not that cmux broke.
    @Test func anUnusableOutputPathIsTheCallersParameter() {
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingSessionError.outputNotAFile("/tmp")
            ) == "invalid_params"
        )
    }

    /// A geometry failure is only the caller's parameter when a parameter can
    /// fix it. An agent that reads `invalid_params` edits its flags and tries
    /// again, so a window with nothing to capture has to say `not_found`
    /// instead: no `--region`, `--scale` or `--max-width` makes it capturable.
    @Test func geometryFailuresSeparateFlagsFromAnEmptyWindow() {
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingFrameGeometry.Failure.regionOutsideWindow
            ) == "invalid_params"
        )
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingFrameGeometry.Failure.gifFrameTooLarge
            ) == "invalid_params"
        )
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingFrameGeometry.Failure.emptyWindow
            ) == "not_found"
        )
    }

    @Test func anUnrecognizedErrorStaysAnInternalError() {
        struct Surprise: Error {}
        #expect(TerminalController.recordingErrorCode(for: Surprise()) == "internal_error")
    }
}
