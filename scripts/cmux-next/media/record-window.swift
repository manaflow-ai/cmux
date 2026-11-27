// Platform bridge only: ScreenCaptureKit owns capture, timestamps and movie encoding.
// Python owns route selection, lifetime and publication. Requires macOS 15+.
import AppKit
import AVFoundation
import ScreenCaptureKit

@available(macOS 15.0, *)
final class MovieOutput: NSObject, SCRecordingOutputDelegate {
    let finished = DispatchSemaphore(value: 0)
    var failure: Error?

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        print("READY")
        fflush(stdout)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        failure = error
        finished.signal()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finished.signal()
    }
}

@main
struct WindowMovie {
    static func main() async {
        do {
            guard #available(macOS 15.0, *) else { throw CaptureError.message("macOS 15 is required") }
            // A capture job must already have permission; never open a prompt on a shared runner.
            guard CGPreflightScreenCaptureAccess() else { throw CaptureError.message("no Screen Recording grant") }
            // --menus: the app's open native menus too. A popup menu is its own window, never a child of the main
            // window, so a recording of that window alone leaves it out (What's New `customizations-menu`).
            let arguments = CommandLine.arguments.filter { $0 != "--menus" }
            let menus = arguments.count < CommandLine.arguments.count
            guard arguments.count == 3, let pid = Int32(arguments[1]) else {
                throw CaptureError.message("usage: record-window PID OUTPUT.mov [--menus]")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw CaptureError.message("no app window")
            }
            let filter: SCContentFilter
            let config = SCStreamConfiguration()
            var size = window.frame.size
            if menus {
                // Every window of this app (its menus among them) on the window's display, cut to the window's
                // frame: never another app's window, so concurrent tours on one console stay out.
                guard let app = window.owningApplication,
                      let display = content.displays.max(by: { $0.frame.intersection(window.frame).area < $1.frame.intersection(window.frame).area }),
                      display.frame.intersects(window.frame) else {
                    throw CaptureError.message("no display under the app window")
                }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                config.sourceRect = window.frame.intersection(display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                size = config.sourceRect.size
            } else {
                filter = SCContentFilter(desktopIndependentWindow: window)
                size = filter.contentRect.size
            }
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.width = Int(size.width * CGFloat(filter.pointPixelScale)) / 2 * 2
            config.height = Int(size.height * CGFloat(filter.pointPixelScale)) / 2 * 2
            config.includeChildWindows = true
            config.showsCursor = false
            config.capturesAudio = false
            config.ignoreShadowsSingleWindow = true
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let outputConfig = SCRecordingOutputConfiguration()
            outputConfig.outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
            outputConfig.outputFileType = .mov
            outputConfig.videoCodecType = .h264
            let delegate = MovieOutput()
            let output = SCRecordingOutput(configuration: outputConfig, delegate: delegate)
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            // EOF as well as a newline stops capture when the Python parent exits.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
                    _ = poll(&input, 1, 300_000)
                    continuation.resume()
                }
            }
            try await stream.stopCapture()
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<DispatchTimeoutResult, Never>) in
                DispatchQueue.global().async {
                    continuation.resume(returning: delegate.finished.wait(timeout: .now() + 15))
                }
            }
            guard result == .success else { throw CaptureError.message("movie finalization timed out") }
            if let error = delegate.failure { throw error }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    enum CaptureError: Error { case message(String) }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
