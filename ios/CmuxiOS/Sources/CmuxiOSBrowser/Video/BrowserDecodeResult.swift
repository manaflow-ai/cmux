/// Carries a synchronous decode callback's failure back to the caller.
/// Justification for unchecked Sendable: VideoToolbox runs the handler on
/// the calling thread before `VTDecompressionSessionDecodeFrame` returns
/// (no asynchronous-decode flag), so there is no concurrent access.
final class BrowserDecodeResult: @unchecked Sendable {
    var failed = false
}
