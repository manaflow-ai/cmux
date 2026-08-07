import Foundation
import OwlMojoBindingsGenerated

public protocol OwlBrowserRuntime: OwlFreshMojoPipeBindings {
    var runtimeDescription: String { get }

    func initialize() throws
    func createSession(
        chromiumHost: String,
        initialURL: String,
        userDataDirectory: String,
        events: OwlBrowserSessionEvents
    ) throws -> OpaquePointer
    func destroy(_ session: OpaquePointer?)
    func hostPID(_ session: OpaquePointer?) -> Int32
    func pollEvents(milliseconds: UInt32)
    func executeJavaScript(_ session: OpaquePointer?, script: String) throws -> String
}

public extension OwlBrowserRuntime {
    var runtimeDescription: String {
        "\(String(describing: type(of: self))) generated Mojo pipe bindings"
    }

    func captureSurfacePNG(_ session: OpaquePointer?, to url: URL) throws -> OwlBrowserSurfaceCapture {
        let result = try surfaceTreeHostCaptureSurface(session)
        guard result.error.isEmpty else {
            throw OwlBrowserError.capture("CaptureSurface failed: \(result.error)")
        }
        let data = Data(result.png)
        guard !data.isEmpty else {
            throw OwlBrowserError.capture("CaptureSurface returned empty PNG data")
        }
        try data.write(to: url)
        return OwlBrowserSurfaceCapture(path: url.path, mode: result.captureMode, width: result.width, height: result.height)
    }
}
