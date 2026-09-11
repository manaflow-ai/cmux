import Foundation
import OwlMojoBindingsGenerated

open class OwlCBrowserRuntime: OwlBrowserRuntime {
    private let globalInit: OwlBrowserRuntimeGlobalInit
    private let sessionCreate: OwlBrowserRuntimeSessionCreate
    private let sessionDestroy: OwlBrowserRuntimeSessionDestroy
    private let sessionHostPID: OwlBrowserRuntimeHostPID
    private let shellExecuteJavaScript: OwlBrowserRuntimeStringInputResult
    private let sessionSetClientSymbol: OwlBrowserRuntimeVoidUInt64
    private let sessionBindProfileSymbol: OwlBrowserRuntimeVoidUInt64
    private let sessionBindWebViewSymbol: OwlBrowserRuntimeVoidUInt64
    private let sessionBindInputSymbol: OwlBrowserRuntimeVoidUInt64
    private let sessionBindSurfaceTreeSymbol: OwlBrowserRuntimeVoidUInt64
    private let sessionBindNativeSurfaceHostSymbol: OwlBrowserRuntimeVoidUInt64
    private let sessionBindDevToolsHostSymbol: OwlBrowserRuntimeVoidUInt64
    private let sessionFlushSymbol: OwlBrowserRuntimeBoolOut
    private let profileGetPathSymbol: OwlBrowserRuntimeStringOut
    private let webViewNavigateSymbol: OwlBrowserRuntimeVoidString
    private let webViewResizeSymbol: OwlBrowserRuntimeWebViewResize
    private let webViewSetFocusSymbol: OwlBrowserRuntimeVoidBool
    private let inputSendMouseSymbol: OwlBrowserRuntimeInputSendMouse
    private let inputSendKeySymbol: OwlBrowserRuntimeInputSendKey
    private let surfaceTreeCaptureSurfaceJSON: OwlBrowserRuntimeStringOut
    private let surfaceTreeGetJSON: OwlBrowserRuntimeStringOut
    private let nativeSurfaceAcceptSymbol: OwlBrowserRuntimeNativeSurfaceAccept
    private let nativeSurfaceCancelSymbol: OwlBrowserRuntimeBoolOut
    private let nativeSurfaceSelectFilePickerFilesJSONSymbol: OwlBrowserRuntimeStringInputBoolOut
    private let nativeSurfaceCancelFilePickerSymbol: OwlBrowserRuntimeBoolOut
    private let devToolsOpenSymbol: OwlBrowserRuntimeDevToolsOpen
    private let devToolsCloseSymbol: OwlBrowserRuntimeBoolOut
    private let devToolsEvaluateJavaScriptSymbol: OwlBrowserRuntimeStringInputResult
    private let eventPoll: OwlBrowserRuntimePollEvents
    private let freeBuffer: OwlBrowserRuntimeFreeBuffer

    open var runtimeDescription: String {
        "OwlCBrowserRuntime generated Mojo pipe bindings with injected typed C-ABI symbols"
    }

    public init(symbols: OwlBrowserRuntimeSymbols) {
        self.globalInit = symbols.globalInit
        self.sessionCreate = symbols.sessionCreate
        self.sessionDestroy = symbols.sessionDestroy
        self.sessionHostPID = symbols.sessionHostPID
        self.shellExecuteJavaScript = symbols.shellExecuteJavaScript
        self.sessionSetClientSymbol = symbols.sessionSetClient
        self.sessionBindProfileSymbol = symbols.sessionBindProfile
        self.sessionBindWebViewSymbol = symbols.sessionBindWebView
        self.sessionBindInputSymbol = symbols.sessionBindInput
        self.sessionBindSurfaceTreeSymbol = symbols.sessionBindSurfaceTree
        self.sessionBindNativeSurfaceHostSymbol = symbols.sessionBindNativeSurfaceHost
        self.sessionBindDevToolsHostSymbol = symbols.sessionBindDevToolsHost
        self.sessionFlushSymbol = symbols.sessionFlush
        self.profileGetPathSymbol = symbols.profileGetPath
        self.webViewNavigateSymbol = symbols.webViewNavigate
        self.webViewResizeSymbol = symbols.webViewResize
        self.webViewSetFocusSymbol = symbols.webViewSetFocus
        self.inputSendMouseSymbol = symbols.inputSendMouse
        self.inputSendKeySymbol = symbols.inputSendKey
        self.surfaceTreeCaptureSurfaceJSON = symbols.surfaceTreeCaptureSurfaceJSON
        self.surfaceTreeGetJSON = symbols.surfaceTreeGetJSON
        self.nativeSurfaceAcceptSymbol = symbols.nativeSurfaceAccept
        self.nativeSurfaceCancelSymbol = symbols.nativeSurfaceCancel
        self.nativeSurfaceSelectFilePickerFilesJSONSymbol = symbols.nativeSurfaceSelectFilePickerFilesJSON
        self.nativeSurfaceCancelFilePickerSymbol = symbols.nativeSurfaceCancelFilePicker
        self.devToolsOpenSymbol = symbols.devToolsOpen
        self.devToolsCloseSymbol = symbols.devToolsClose
        self.devToolsEvaluateJavaScriptSymbol = symbols.devToolsEvaluateJavaScript
        self.eventPoll = symbols.eventPoll
        self.freeBuffer = symbols.freeBuffer
    }

    public func initialize() throws {
        let status = globalInit()
        guard status == 0 else {
            throw OwlBrowserError.bridge("owl_fresh_mojo_global_init failed with status \(status)")
        }
    }

    public func createSession(
        chromiumHost: String,
        initialURL: String,
        userDataDirectory: String,
        events: OwlBrowserSessionEvents
    ) throws -> OpaquePointer {
        let userData = Unmanaged.passUnretained(events).toOpaque()
        let session = chromiumHost.withCString { hostPointer in
            initialURL.withCString { urlPointer in
                userDataDirectory.withCString { profilePointer in
                    sessionCreate(hostPointer, urlPointer, profilePointer, owlFreshEventCallback, userData)
                }
            }
        }
        guard let session else {
            throw OwlBrowserError.launch("owl_fresh_mojo_session_create returned null")
        }
        return session
    }

    public func destroy(_ session: OpaquePointer?) {
        sessionDestroy(session)
    }

    public func hostPID(_ session: OpaquePointer?) -> Int32 {
        sessionHostPID(session)
    }

    public func pollEvents(milliseconds: UInt32) {
        eventPoll(milliseconds)
    }

    public func executeJavaScript(_ session: OpaquePointer?, script: String) throws -> String {
        try script.withCString { scriptPointer in
            try callStringResult("ShellController.executeJavaScript") { resultPointer, errorPointer in
                shellExecuteJavaScript(session, scriptPointer, resultPointer, errorPointer)
            }
        }
    }

    public func sessionSetClient(_ session: OpaquePointer?, client: OwlFreshClientRemote) throws {
        try callVoidResult("OwlFreshSession.setClient") { errorPointer in
            sessionSetClientSymbol(session, client.handle, errorPointer)
        }
    }

    public func sessionBindProfile(_ session: OpaquePointer?, profile: OwlFreshProfileReceiver) throws {
        try callVoidResult("OwlFreshSession.bindProfile") { errorPointer in
            sessionBindProfileSymbol(session, profile.handle, errorPointer)
        }
    }

    public func sessionBindWebView(_ session: OpaquePointer?, webView: OwlFreshWebViewReceiver) throws {
        try callVoidResult("OwlFreshSession.bindWebView") { errorPointer in
            sessionBindWebViewSymbol(session, webView.handle, errorPointer)
        }
    }

    public func sessionBindInput(_ session: OpaquePointer?, input: OwlFreshInputReceiver) throws {
        try callVoidResult("OwlFreshSession.bindInput") { errorPointer in
            sessionBindInputSymbol(session, input.handle, errorPointer)
        }
    }

    public func sessionBindSurfaceTree(
        _ session: OpaquePointer?,
        surfaceTree: OwlFreshSurfaceTreeHostReceiver
    ) throws {
        try callVoidResult("OwlFreshSession.bindSurfaceTree") { errorPointer in
            sessionBindSurfaceTreeSymbol(session, surfaceTree.handle, errorPointer)
        }
    }

    public func sessionBindNativeSurfaceHost(
        _ session: OpaquePointer?,
        nativeSurfaceHost: OwlFreshNativeSurfaceHostReceiver
    ) throws {
        try callVoidResult("OwlFreshSession.bindNativeSurfaceHost") { errorPointer in
            sessionBindNativeSurfaceHostSymbol(session, nativeSurfaceHost.handle, errorPointer)
        }
    }

    public func sessionBindDevToolsHost(
        _ session: OpaquePointer?,
        devtoolsHost: OwlFreshDevToolsHostReceiver
    ) throws {
        try callVoidResult("OwlFreshSession.bindDevToolsHost") { errorPointer in
            sessionBindDevToolsHostSymbol(session, devtoolsHost.handle, errorPointer)
        }
    }

    public func sessionFlush(_ session: OpaquePointer?) throws -> Bool {
        try callBoolResult("OwlFreshSession.flush") { okPointer, errorPointer in
            sessionFlushSymbol(session, okPointer, errorPointer)
        }
    }

    public func profileGetPath(_ session: OpaquePointer?) throws -> String {
        try callStringResult("OwlFreshProfile.getPath") { resultPointer, errorPointer in
            profileGetPathSymbol(session, resultPointer, errorPointer)
        }
    }

    public func webViewNavigate(_ session: OpaquePointer?, url: String) throws {
        try url.withCString { urlPointer in
            try callVoidResult("OwlFreshWebView.navigate") { errorPointer in
                webViewNavigateSymbol(session, urlPointer, errorPointer)
            }
        }
    }

    public func webViewResize(_ session: OpaquePointer?, request: OwlFreshWebViewResizeRequest) throws {
        try callVoidResult("OwlFreshWebView.resize") { errorPointer in
            webViewResizeSymbol(session, request.width, request.height, request.scale, errorPointer)
        }
    }

    public func webViewSetFocus(_ session: OpaquePointer?, focused: Bool) throws {
        try callVoidResult("OwlFreshWebView.setFocus") { errorPointer in
            webViewSetFocusSymbol(session, focused, errorPointer)
        }
    }

    public func inputSendMouse(_ session: OpaquePointer?, event: OwlFreshMouseEvent) throws {
        try callVoidResult("OwlFreshInput.sendMouse") { errorPointer in
            inputSendMouseSymbol(
                session,
                event.kind.rawValue,
                event.x,
                event.y,
                event.button,
                event.clickCount,
                event.deltaX,
                event.deltaY,
                event.modifiers,
                errorPointer
            )
        }
    }

    public func inputSendKey(_ session: OpaquePointer?, event: OwlFreshKeyEvent) throws {
        try event.text.withCString { textPointer in
            try callVoidResult("OwlFreshInput.sendKey") { errorPointer in
                inputSendKeySymbol(
                    session,
                    event.keyDown,
                    event.keyCode,
                    textPointer,
                    event.modifiers,
                    errorPointer
                )
            }
        }
    }

    public func surfaceTreeHostCaptureSurface(_ session: OpaquePointer?) throws -> OwlFreshCaptureResult {
        let json = try callStringResult("OwlFreshSurfaceTreeHost.captureSurface") { resultPointer, errorPointer in
            surfaceTreeCaptureSurfaceJSON(session, resultPointer, errorPointer)
        }
        let result = try JSONDecoder().decode(RuntimeCaptureSurfaceResult.self, from: Data(json.utf8))
        let png = Data(base64Encoded: result.pngBase64).map(Array.init) ?? []
        return OwlFreshCaptureResult(
            png: png,
            width: result.width,
            height: result.height,
            captureMode: result.captureMode,
            error: result.error
        )
    }

    public func surfaceTreeHostGetSurfaceTree(_ session: OpaquePointer?) throws -> OwlFreshSurfaceTree {
        let json = try callStringResult("OwlFreshSurfaceTreeHost.getSurfaceTree") { resultPointer, errorPointer in
            surfaceTreeGetJSON(session, resultPointer, errorPointer)
        }
        return try JSONDecoder().decode(OwlFreshSurfaceTree.self, from: Data(json.utf8))
    }

    public func nativeSurfaceHostAcceptActivePopupMenuItem(_ session: OpaquePointer?, index: UInt32) throws -> Bool {
        try callBoolResult("OwlFreshNativeSurfaceHost.acceptActivePopupMenuItem") { okPointer, errorPointer in
            nativeSurfaceAcceptSymbol(session, index, okPointer, errorPointer)
        }
    }

    public func nativeSurfaceHostCancelActivePopup(_ session: OpaquePointer?) throws -> Bool {
        try callBoolResult("OwlFreshNativeSurfaceHost.cancelActivePopup") { okPointer, errorPointer in
            nativeSurfaceCancelSymbol(session, okPointer, errorPointer)
        }
    }

    public func nativeSurfaceHostSelectActiveFilePickerFiles(
        _ session: OpaquePointer?,
        paths: [String]
    ) throws -> Bool {
        let data = try JSONEncoder().encode(paths)
        let json = String(decoding: data, as: UTF8.self)
        return try json.withCString { jsonPointer in
            try callBoolResult("OwlFreshNativeSurfaceHost.selectActiveFilePickerFiles") { okPointer, errorPointer in
                nativeSurfaceSelectFilePickerFilesJSONSymbol(session, jsonPointer, okPointer, errorPointer)
            }
        }
    }

    public func nativeSurfaceHostCancelActiveFilePicker(_ session: OpaquePointer?) throws -> Bool {
        try callBoolResult("OwlFreshNativeSurfaceHost.cancelActiveFilePicker") { okPointer, errorPointer in
            nativeSurfaceCancelFilePickerSymbol(session, okPointer, errorPointer)
        }
    }

    public func devToolsHostOpenDevTools(
        _ session: OpaquePointer?,
        mode: OwlFreshDevToolsMode
    ) throws -> Bool {
        try callBoolResult("OwlFreshDevToolsHost.openDevTools") { okPointer, errorPointer in
            devToolsOpenSymbol(session, mode.rawValue, okPointer, errorPointer)
        }
    }

    public func devToolsHostCloseDevTools(_ session: OpaquePointer?) throws -> Bool {
        try callBoolResult("OwlFreshDevToolsHost.closeDevTools") { okPointer, errorPointer in
            devToolsCloseSymbol(session, okPointer, errorPointer)
        }
    }

    public func devToolsHostEvaluateDevToolsJavaScript(
        _ session: OpaquePointer?,
        script: String
    ) throws -> String {
        try script.withCString { scriptPointer in
            try callStringResult("OwlFreshDevToolsHost.evaluateDevToolsJavaScript") { resultPointer, errorPointer in
                devToolsEvaluateJavaScriptSymbol(session, scriptPointer, resultPointer, errorPointer)
            }
        }
    }

    private func callStringResult(
        _ context: String,
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> Int32
    ) throws -> String {
        var resultPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = body(&resultPointer, &errorPointer)
        defer {
            if let resultPointer {
                freeBuffer(UnsafeMutableRawPointer(resultPointer))
            }
            if let errorPointer {
                freeBuffer(UnsafeMutableRawPointer(errorPointer))
            }
        }
        if status != 0 {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown Mojo runtime error"
            throw OwlBrowserError.bridge("\(context) failed: \(message)")
        }
        return resultPointer.map { String(cString: $0) } ?? ""
    }

    private func callBoolResult(
        _ context: String,
        _ body: (
            UnsafeMutablePointer<Bool>,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> Int32
    ) throws -> Bool {
        var ok = false
        try callVoidResult(context) { errorPointer in
            body(&ok, errorPointer)
        }
        return ok
    }

    private func callVoidResult(
        _ context: String,
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = body(&errorPointer)
        defer {
            if let errorPointer {
                freeBuffer(UnsafeMutableRawPointer(errorPointer))
            }
        }
        if status != 0 {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown Mojo runtime error"
            throw OwlBrowserError.bridge("\(context) failed: \(message)")
        }
    }
}

private struct RuntimeCaptureSurfaceResult: Decodable {
    let pngBase64: String
    let width: UInt32
    let height: UInt32
    let captureMode: String
    let error: String
}
