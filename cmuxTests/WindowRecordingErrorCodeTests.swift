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
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingSessionError.composeFailed) == "internal_error")
        #expect(TerminalController.recordingErrorCode(for: WindowRecordingSessionError.alreadyFinished) == "internal_error")
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingSessionError.captureFailed("no window server")
            ) == "internal_error"
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

    @Test func geometryFailuresAreParameterFailures() {
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingFrameGeometry.Failure.regionOutsideWindow
            ) == "invalid_params"
        )
        #expect(
            TerminalController.recordingErrorCode(
                for: WindowRecordingFrameGeometry.Failure.emptyWindow
            ) == "invalid_params"
        )
    }

    @Test func anUnrecognizedErrorStaysAnInternalError() {
        struct Surprise: Error {}
        #expect(TerminalController.recordingErrorCode(for: Surprise()) == "internal_error")
    }
}
