import Darwin
import XCTest
import OwlBrowserCore
import OwlMojoBindingsGenerated

final class OwlBrowserCoreTests: XCTestCase {
    func testSessionControllerBindsGeneratedChildInterfacesBeforeUse() throws {
        let pipe = FakeBrowserPipe()
        let controller = try OwlBrowserSessionController(pipe: pipe, session: nil)

        try controller.resize(OwlFreshWebViewResizeRequest(width: 960, height: 640, scale: 1.0))
        try controller.sendKey(OwlFreshKeyEvent(keyDown: true, keyCode: 13, text: "\n", modifiers: 0))
        _ = try controller.getSurfaceTree()

        XCTAssertEqual(pipe.calls, [
            "bindProfile:1",
            "bindWebView:2",
            "bindInput:3",
            "bindSurfaceTree:4",
            "bindNativeSurfaceHost:5",
            "bindDevToolsHost:6",
            "setClient:7",
            "resize:960x640@1.0",
            "key:13:\n",
            "surfaceTree",
        ])
        XCTAssertEqual(controller.recordedCalls.prefix(7).map(\.method), [
            "bindProfile",
            "bindWebView",
            "bindInput",
            "bindSurfaceTree",
            "bindNativeSurfaceHost",
            "bindDevToolsHost",
            "setClient",
        ])
    }

    func testCBrowserRuntimeConsumesInjectedSymbolsWithoutDynamicLibrary() async throws {
        FakeRuntimeCABI.reset()
        let runtime = OwlCBrowserRuntime(symbols: FakeRuntimeCABI.symbols())
        XCTAssertEqual(
            runtime.runtimeDescription,
            "OwlCBrowserRuntime generated Mojo pipe bindings with injected typed C-ABI symbols"
        )
        try runtime.initialize()
        let events = OwlBrowserSessionEvents()
        let session = try runtime.createSession(
            chromiumHost: "content_shell",
            initialURL: "https://example.com",
            userDataDirectory: "/tmp/owl-profile",
            events: events
        )
        XCTAssertEqual(runtime.hostPID(session), 4242)
        runtime.pollEvents(milliseconds: 7)

        let controller = try OwlBrowserSessionController(pipe: runtime, session: session)
        try controller.navigate("https://example.com")
        try controller.resize(OwlFreshWebViewResizeRequest(width: 800, height: 600, scale: 2.0))
        try controller.setFocus(true)
        try controller.sendMouse(OwlFreshMouseEvent(
            kind: .down,
            x: 12,
            y: 34,
            button: 1,
            clickCount: 1,
            deltaX: 0,
            deltaY: 0,
            modifiers: 0
        ))
        try controller.sendKey(OwlFreshKeyEvent(keyDown: true, keyCode: 36, text: "\n", modifiers: 8))
        let flushed = try await controller.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try controller.getSurfaceTree().generation, 99)
        XCTAssertEqual(try runtime.executeJavaScript(session, script: "window.owl"), "{\"ok\":true}")

        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("owl-c-runtime-\(UUID().uuidString).png")
        let capture = try runtime.captureSurfacePNG(session, to: captureURL)
        defer { try? FileManager.default.removeItem(at: captureURL) }
        XCTAssertEqual(capture.width, 2)
        XCTAssertEqual(capture.height, 1)
        XCTAssertEqual(try Data(contentsOf: captureURL), Data([1, 2, 3]))

        XCTAssertTrue(try controller.acceptActivePopupMenuItem(2))
        XCTAssertTrue(try controller.cancelActivePopup())
        XCTAssertTrue(try controller.selectActiveFilePickerFiles(["/tmp/owl-file.txt"]))
        XCTAssertTrue(try controller.cancelActiveFilePicker())
        let devToolsOpened = try controller.openDevTools(.bottom)
        let devToolsResult = try controller.evaluateDevToolsJavaScript("window.owlDevTools")
        let devToolsClosed = try controller.closeDevTools()
        XCTAssertTrue(devToolsOpened)
        XCTAssertEqual(devToolsResult, "{\"proof\":true}")
        XCTAssertTrue(devToolsClosed)
        runtime.destroy(session)

        XCTAssertEqual(FakeRuntimeCABI.calls, [
            "globalInit",
            "create:content_shell:https://example.com:/tmp/owl-profile",
            "hostPID",
            "poll:7",
            "bindProfile:1",
            "bindWebView:2",
            "bindInput:3",
            "bindSurfaceTree:4",
            "bindNativeSurfaceHost:5",
            "bindDevToolsHost:6",
            "setClient:7",
            "navigate:https://example.com",
            "resize:800x600@2.0",
            "focus:true",
            "mouse:down:12.0:34.0",
            "key:36:\n:8",
            "flush",
            "surfaceTree",
            "js:window.owl",
            "capture",
            "accept:2",
            "cancel",
            #"filePickerSelect:["\/tmp\/owl-file.txt"]"#,
            "filePickerCancel",
            "devToolsOpen:0",
            "devToolsJS:window.owlDevTools",
            "devToolsClose",
            "destroy",
        ])
    }
}

private final class FakeBrowserPipe: OwlFreshMojoPipeBindings {
    var calls: [String] = []

    func sessionSetClient(_ session: OpaquePointer?, client: OwlFreshClientRemote) throws {
        calls.append("setClient:\(client.handle)")
    }

    func sessionBindProfile(_ session: OpaquePointer?, profile: OwlFreshProfileReceiver) throws {
        calls.append("bindProfile:\(profile.handle)")
    }

    func sessionBindWebView(_ session: OpaquePointer?, webView: OwlFreshWebViewReceiver) throws {
        calls.append("bindWebView:\(webView.handle)")
    }

    func sessionBindInput(_ session: OpaquePointer?, input: OwlFreshInputReceiver) throws {
        calls.append("bindInput:\(input.handle)")
    }

    func sessionBindSurfaceTree(_ session: OpaquePointer?, surfaceTree: OwlFreshSurfaceTreeHostReceiver) throws {
        calls.append("bindSurfaceTree:\(surfaceTree.handle)")
    }

    func sessionBindNativeSurfaceHost(
        _ session: OpaquePointer?,
        nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver
    ) throws {
        calls.append("bindNativeSurfaceHost:\(nativeSurfaceHost.handle)")
    }

    func sessionBindDevToolsHost(
        _ session: OpaquePointer?,
        devtoolsHost: OwlFreshDevToolsHostReceiver
    ) throws {
        calls.append("bindDevToolsHost:\(devtoolsHost.handle)")
    }

    func sessionFlush(_ session: OpaquePointer?) throws -> Bool {
        calls.append("flush")
        return true
    }

    func profileGetPath(_ session: OpaquePointer?) throws -> String {
        calls.append("profile")
        return "/tmp/owl-profile"
    }

    func webViewNavigate(_ session: OpaquePointer?, url: String) throws {
        calls.append("navigate:\(url)")
    }

    func webViewResize(_ session: OpaquePointer?, request: OwlFreshWebViewResizeRequest) throws {
        calls.append("resize:\(request.width)x\(request.height)@\(request.scale)")
    }

    func webViewSetFocus(_ session: OpaquePointer?, focused: Bool) throws {
        calls.append("focus:\(focused)")
    }

    func inputSendMouse(_ session: OpaquePointer?, event: OwlFreshMouseEvent) throws {
        calls.append("mouse:\(event.kind.rawValue)")
    }

    func inputSendKey(_ session: OpaquePointer?, event: OwlFreshKeyEvent) throws {
        calls.append("key:\(event.keyCode):\(event.text)")
    }

    func surfaceTreeHostCaptureSurface(_ session: OpaquePointer?) throws -> OwlFreshCaptureResult {
        calls.append("capture")
        return OwlFreshCaptureResult(png: [1, 2, 3], width: 1, height: 1, captureMode: "fake", error: "")
    }

    func surfaceTreeHostGetSurfaceTree(_ session: OpaquePointer?) throws -> OwlFreshSurfaceTree {
        calls.append("surfaceTree")
        return OwlFreshSurfaceTree(generation: 1, surfaces: [])
    }

    func nativeSurfaceHostAcceptActivePopupMenuItem(_ session: OpaquePointer?, index: UInt32) throws -> Bool {
        calls.append("accept:\(index)")
        return true
    }

    func nativeSurfaceHostCancelActivePopup(_ session: OpaquePointer?) throws -> Bool {
        calls.append("cancel")
        return true
    }

    func nativeSurfaceHostSelectActiveFilePickerFiles(_ session: OpaquePointer?, paths: [String]) throws -> Bool {
        calls.append("filePickerSelect:\(paths.joined(separator: ","))")
        return true
    }

    func nativeSurfaceHostCancelActiveFilePicker(_ session: OpaquePointer?) throws -> Bool {
        calls.append("filePickerCancel")
        return true
    }

    func devToolsHostOpenDevTools(_ session: OpaquePointer?, mode: OwlFreshDevToolsMode) throws -> Bool {
        calls.append("devToolsOpen:\(mode.rawValue)")
        return true
    }

    func devToolsHostCloseDevTools(_ session: OpaquePointer?) throws -> Bool {
        calls.append("devToolsClose")
        return true
    }

    func devToolsHostEvaluateDevToolsJavaScript(_ session: OpaquePointer?, script: String) throws -> String {
        calls.append("devToolsJS:\(script)")
        return "{\"proof\":true}"
    }
}

private enum FakeRuntimeCABI {
    static var calls: [String] = []
    static let session = OpaquePointer(bitPattern: 0xCAFE)!

    static func reset() {
        calls = []
    }

    static func symbols() -> OwlBrowserRuntimeSymbols {
        OwlBrowserRuntimeSymbols(
            globalInit: fakeRuntimeGlobalInit,
            sessionCreate: fakeRuntimeSessionCreate,
            sessionDestroy: fakeRuntimeSessionDestroy,
            sessionHostPID: fakeRuntimeSessionHostPID,
            shellExecuteJavaScript: fakeRuntimeShellExecuteJavaScript,
            sessionSetClient: fakeRuntimeSessionSetClient,
            sessionBindProfile: fakeRuntimeSessionBindProfile,
            sessionBindWebView: fakeRuntimeSessionBindWebView,
            sessionBindInput: fakeRuntimeSessionBindInput,
            sessionBindSurfaceTree: fakeRuntimeSessionBindSurfaceTree,
            sessionBindNativeSurfaceHost: fakeRuntimeSessionBindNativeSurfaceHost,
            sessionBindDevToolsHost: fakeRuntimeSessionBindDevToolsHost,
            sessionFlush: fakeRuntimeSessionFlush,
            profileGetPath: fakeRuntimeProfileGetPath,
            webViewNavigate: fakeRuntimeWebViewNavigate,
            webViewResize: fakeRuntimeWebViewResize,
            webViewSetFocus: fakeRuntimeWebViewSetFocus,
            inputSendMouse: fakeRuntimeInputSendMouse,
            inputSendKey: fakeRuntimeInputSendKey,
            surfaceTreeCaptureSurfaceJSON: fakeRuntimeSurfaceTreeCaptureSurfaceJSON,
            surfaceTreeGetJSON: fakeRuntimeSurfaceTreeGetJSON,
            nativeSurfaceAccept: fakeRuntimeNativeSurfaceAccept,
            nativeSurfaceCancel: fakeRuntimeNativeSurfaceCancel,
            nativeSurfaceSelectFilePickerFilesJSON: fakeRuntimeNativeSurfaceSelectFilePickerFilesJSON,
            nativeSurfaceCancelFilePicker: fakeRuntimeNativeSurfaceCancelFilePicker,
            devToolsOpen: fakeRuntimeDevToolsOpen,
            devToolsClose: fakeRuntimeDevToolsClose,
            devToolsEvaluateJavaScript: fakeRuntimeDevToolsEvaluateJavaScript,
            eventPoll: fakeRuntimeEventPoll,
            freeBuffer: fakeRuntimeFreeBuffer
        )
    }

    fileprivate static func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    fileprivate static func writeCString(
        _ value: String,
        to output: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) {
        output?.pointee = strdup(value)
    }

    fileprivate static func mouseKind(_ rawValue: UInt32) -> String {
        OwlFreshMouseKind(rawValue: rawValue).map(String.init(describing:)) ?? String(rawValue)
    }
}

private let fakeRuntimeGlobalInit: OwlBrowserRuntimeGlobalInit = {
    FakeRuntimeCABI.calls.append("globalInit")
    return 0
}

private let fakeRuntimeSessionCreate: OwlBrowserRuntimeSessionCreate = { host, url, profile, _, _ in
    FakeRuntimeCABI.calls.append(
        "create:\(FakeRuntimeCABI.string(host)):\(FakeRuntimeCABI.string(url)):\(FakeRuntimeCABI.string(profile))"
    )
    return FakeRuntimeCABI.session
}

private let fakeRuntimeSessionDestroy: OwlBrowserRuntimeSessionDestroy = { _ in
    FakeRuntimeCABI.calls.append("destroy")
}

private let fakeRuntimeSessionHostPID: OwlBrowserRuntimeHostPID = { _ in
    FakeRuntimeCABI.calls.append("hostPID")
    return 4242
}

private let fakeRuntimeShellExecuteJavaScript: OwlBrowserRuntimeStringInputResult = { _, script, result, _ in
    FakeRuntimeCABI.calls.append("js:\(FakeRuntimeCABI.string(script))")
    FakeRuntimeCABI.writeCString("{\"ok\":true}", to: result)
    return 0
}

private let fakeRuntimeSessionSetClient: OwlBrowserRuntimeVoidUInt64 = { _, handle, _ in
    FakeRuntimeCABI.calls.append("setClient:\(handle)")
    return 0
}

private let fakeRuntimeSessionBindProfile: OwlBrowserRuntimeVoidUInt64 = { _, handle, _ in
    FakeRuntimeCABI.calls.append("bindProfile:\(handle)")
    return 0
}

private let fakeRuntimeSessionBindWebView: OwlBrowserRuntimeVoidUInt64 = { _, handle, _ in
    FakeRuntimeCABI.calls.append("bindWebView:\(handle)")
    return 0
}

private let fakeRuntimeSessionBindInput: OwlBrowserRuntimeVoidUInt64 = { _, handle, _ in
    FakeRuntimeCABI.calls.append("bindInput:\(handle)")
    return 0
}

private let fakeRuntimeSessionBindSurfaceTree: OwlBrowserRuntimeVoidUInt64 = { _, handle, _ in
    FakeRuntimeCABI.calls.append("bindSurfaceTree:\(handle)")
    return 0
}

private let fakeRuntimeSessionBindNativeSurfaceHost: OwlBrowserRuntimeVoidUInt64 = { _, handle, _ in
    FakeRuntimeCABI.calls.append("bindNativeSurfaceHost:\(handle)")
    return 0
}

private let fakeRuntimeSessionBindDevToolsHost: OwlBrowserRuntimeVoidUInt64 = { _, handle, _ in
    FakeRuntimeCABI.calls.append("bindDevToolsHost:\(handle)")
    return 0
}

private let fakeRuntimeSessionFlush: OwlBrowserRuntimeBoolOut = { _, ok, _ in
    FakeRuntimeCABI.calls.append("flush")
    ok?.pointee = true
    return 0
}

private let fakeRuntimeProfileGetPath: OwlBrowserRuntimeStringOut = { _, result, _ in
    FakeRuntimeCABI.calls.append("profilePath")
    FakeRuntimeCABI.writeCString("/tmp/owl-profile", to: result)
    return 0
}

private let fakeRuntimeWebViewNavigate: OwlBrowserRuntimeVoidString = { _, url, _ in
    FakeRuntimeCABI.calls.append("navigate:\(FakeRuntimeCABI.string(url))")
    return 0
}

private let fakeRuntimeWebViewResize: OwlBrowserRuntimeWebViewResize = { _, width, height, scale, _ in
    FakeRuntimeCABI.calls.append("resize:\(width)x\(height)@\(scale)")
    return 0
}

private let fakeRuntimeWebViewSetFocus: OwlBrowserRuntimeVoidBool = { _, focused, _ in
    FakeRuntimeCABI.calls.append("focus:\(focused)")
    return 0
}

private let fakeRuntimeInputSendMouse: OwlBrowserRuntimeInputSendMouse = { _, kind, x, y, _, _, _, _, _, _ in
    FakeRuntimeCABI.calls.append("mouse:\(FakeRuntimeCABI.mouseKind(kind)):\(x):\(y)")
    return 0
}

private let fakeRuntimeInputSendKey: OwlBrowserRuntimeInputSendKey = { _, _, keyCode, text, modifiers, _ in
    FakeRuntimeCABI.calls.append("key:\(keyCode):\(FakeRuntimeCABI.string(text)):\(modifiers)")
    return 0
}

private let fakeRuntimeSurfaceTreeCaptureSurfaceJSON: OwlBrowserRuntimeStringOut = { _, result, _ in
    FakeRuntimeCABI.calls.append("capture")
    FakeRuntimeCABI.writeCString(
        #"{"pngBase64":"AQID","width":2,"height":1,"captureMode":"fake","error":""}"#,
        to: result
    )
    return 0
}

private let fakeRuntimeSurfaceTreeGetJSON: OwlBrowserRuntimeStringOut = { _, result, _ in
    FakeRuntimeCABI.calls.append("surfaceTree")
    FakeRuntimeCABI.writeCString(#"{"generation":99,"surfaces":[]}"#, to: result)
    return 0
}

private let fakeRuntimeNativeSurfaceAccept: OwlBrowserRuntimeNativeSurfaceAccept = { _, index, ok, _ in
    FakeRuntimeCABI.calls.append("accept:\(index)")
    ok?.pointee = true
    return 0
}

private let fakeRuntimeNativeSurfaceCancel: OwlBrowserRuntimeBoolOut = { _, ok, _ in
    FakeRuntimeCABI.calls.append("cancel")
    ok?.pointee = true
    return 0
}

private let fakeRuntimeNativeSurfaceSelectFilePickerFilesJSON: OwlBrowserRuntimeStringInputBoolOut = { _, paths, ok, _ in
    FakeRuntimeCABI.calls.append("filePickerSelect:\(FakeRuntimeCABI.string(paths))")
    ok?.pointee = true
    return 0
}

private let fakeRuntimeNativeSurfaceCancelFilePicker: OwlBrowserRuntimeBoolOut = { _, ok, _ in
    FakeRuntimeCABI.calls.append("filePickerCancel")
    ok?.pointee = true
    return 0
}

private let fakeRuntimeDevToolsOpen: OwlBrowserRuntimeDevToolsOpen = { _, mode, ok, _ in
    FakeRuntimeCABI.calls.append("devToolsOpen:\(mode)")
    ok?.pointee = true
    return 0
}

private let fakeRuntimeDevToolsClose: OwlBrowserRuntimeBoolOut = { _, ok, _ in
    FakeRuntimeCABI.calls.append("devToolsClose")
    ok?.pointee = true
    return 0
}

private let fakeRuntimeDevToolsEvaluateJavaScript: OwlBrowserRuntimeStringInputResult = { _, script, result, _ in
    FakeRuntimeCABI.calls.append("devToolsJS:\(FakeRuntimeCABI.string(script))")
    FakeRuntimeCABI.writeCString("{\"proof\":true}", to: result)
    return 0
}

private let fakeRuntimeEventPoll: OwlBrowserRuntimePollEvents = { milliseconds in
    FakeRuntimeCABI.calls.append("poll:\(milliseconds)")
}

private let fakeRuntimeFreeBuffer: OwlBrowserRuntimeFreeBuffer = { pointer in
    free(pointer)
}
