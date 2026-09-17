import Foundation

public typealias OwlBrowserRuntimeGlobalInit = @convention(c) () -> Int32
public typealias OwlBrowserRuntimeSessionCreate = @convention(c) (
    UnsafePointer<CChar>,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    OwlFreshEventCallback?,
    UnsafeMutableRawPointer?
) -> OpaquePointer?
public typealias OwlBrowserRuntimeSessionDestroy = @convention(c) (OpaquePointer?) -> Void
public typealias OwlBrowserRuntimeHostPID = @convention(c) (OpaquePointer?) -> Int32
public typealias OwlBrowserRuntimeStringInputResult = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeStringOut = @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeBoolOut = @convention(c) (
    OpaquePointer?,
    UnsafeMutablePointer<Bool>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeVoidUInt64 = @convention(c) (
    OpaquePointer?,
    UInt64,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeVoidString = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeVoidBool = @convention(c) (
    OpaquePointer?,
    Bool,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeWebViewResize = @convention(c) (
    OpaquePointer?,
    UInt32,
    UInt32,
    Float,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeInputSendMouse = @convention(c) (
    OpaquePointer?,
    UInt32,
    Float,
    Float,
    UInt32,
    UInt32,
    Float,
    Float,
    UInt32,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeInputSendKey = @convention(c) (
    OpaquePointer?,
    Bool,
    UInt32,
    UnsafePointer<CChar>?,
    UInt32,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeNativeSurfaceAccept = @convention(c) (
    OpaquePointer?,
    UInt32,
    UnsafeMutablePointer<Bool>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeStringInputBoolOut = @convention(c) (
    OpaquePointer?,
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<Bool>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimeDevToolsOpen = @convention(c) (
    OpaquePointer?,
    UInt32,
    UnsafeMutablePointer<Bool>?,
    UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32
public typealias OwlBrowserRuntimePollEvents = @convention(c) (UInt32) -> Void
public typealias OwlBrowserRuntimeFreeBuffer = @convention(c) (UnsafeMutableRawPointer?) -> Void

public struct OwlBrowserRuntimeSymbols {
    public let globalInit: OwlBrowserRuntimeGlobalInit
    public let sessionCreate: OwlBrowserRuntimeSessionCreate
    public let sessionDestroy: OwlBrowserRuntimeSessionDestroy
    public let sessionHostPID: OwlBrowserRuntimeHostPID
    public let shellExecuteJavaScript: OwlBrowserRuntimeStringInputResult
    public let sessionSetClient: OwlBrowserRuntimeVoidUInt64
    public let sessionBindProfile: OwlBrowserRuntimeVoidUInt64
    public let sessionBindWebView: OwlBrowserRuntimeVoidUInt64
    public let sessionBindInput: OwlBrowserRuntimeVoidUInt64
    public let sessionBindSurfaceTree: OwlBrowserRuntimeVoidUInt64
    public let sessionBindNativeSurfaceHost: OwlBrowserRuntimeVoidUInt64
    public let sessionBindDevToolsHost: OwlBrowserRuntimeVoidUInt64
    public let sessionFlush: OwlBrowserRuntimeBoolOut
    public let profileGetPath: OwlBrowserRuntimeStringOut
    public let webViewNavigate: OwlBrowserRuntimeVoidString
    public let webViewResize: OwlBrowserRuntimeWebViewResize
    public let webViewSetFocus: OwlBrowserRuntimeVoidBool
    public let inputSendMouse: OwlBrowserRuntimeInputSendMouse
    public let inputSendKey: OwlBrowserRuntimeInputSendKey
    public let surfaceTreeCaptureSurfaceJSON: OwlBrowserRuntimeStringOut
    public let surfaceTreeGetJSON: OwlBrowserRuntimeStringOut
    public let nativeSurfaceAccept: OwlBrowserRuntimeNativeSurfaceAccept
    public let nativeSurfaceCancel: OwlBrowserRuntimeBoolOut
    public let nativeSurfaceSelectFilePickerFilesJSON: OwlBrowserRuntimeStringInputBoolOut
    public let nativeSurfaceCancelFilePicker: OwlBrowserRuntimeBoolOut
    public let devToolsOpen: OwlBrowserRuntimeDevToolsOpen
    public let devToolsClose: OwlBrowserRuntimeBoolOut
    public let devToolsEvaluateJavaScript: OwlBrowserRuntimeStringInputResult
    public let eventPoll: OwlBrowserRuntimePollEvents
    public let freeBuffer: OwlBrowserRuntimeFreeBuffer

    public init(
        globalInit: @escaping OwlBrowserRuntimeGlobalInit,
        sessionCreate: @escaping OwlBrowserRuntimeSessionCreate,
        sessionDestroy: @escaping OwlBrowserRuntimeSessionDestroy,
        sessionHostPID: @escaping OwlBrowserRuntimeHostPID,
        shellExecuteJavaScript: @escaping OwlBrowserRuntimeStringInputResult,
        sessionSetClient: @escaping OwlBrowserRuntimeVoidUInt64,
        sessionBindProfile: @escaping OwlBrowserRuntimeVoidUInt64,
        sessionBindWebView: @escaping OwlBrowserRuntimeVoidUInt64,
        sessionBindInput: @escaping OwlBrowserRuntimeVoidUInt64,
        sessionBindSurfaceTree: @escaping OwlBrowserRuntimeVoidUInt64,
        sessionBindNativeSurfaceHost: @escaping OwlBrowserRuntimeVoidUInt64,
        sessionBindDevToolsHost: @escaping OwlBrowserRuntimeVoidUInt64,
        sessionFlush: @escaping OwlBrowserRuntimeBoolOut,
        profileGetPath: @escaping OwlBrowserRuntimeStringOut,
        webViewNavigate: @escaping OwlBrowserRuntimeVoidString,
        webViewResize: @escaping OwlBrowserRuntimeWebViewResize,
        webViewSetFocus: @escaping OwlBrowserRuntimeVoidBool,
        inputSendMouse: @escaping OwlBrowserRuntimeInputSendMouse,
        inputSendKey: @escaping OwlBrowserRuntimeInputSendKey,
        surfaceTreeCaptureSurfaceJSON: @escaping OwlBrowserRuntimeStringOut,
        surfaceTreeGetJSON: @escaping OwlBrowserRuntimeStringOut,
        nativeSurfaceAccept: @escaping OwlBrowserRuntimeNativeSurfaceAccept,
        nativeSurfaceCancel: @escaping OwlBrowserRuntimeBoolOut,
        nativeSurfaceSelectFilePickerFilesJSON: @escaping OwlBrowserRuntimeStringInputBoolOut,
        nativeSurfaceCancelFilePicker: @escaping OwlBrowserRuntimeBoolOut,
        devToolsOpen: @escaping OwlBrowserRuntimeDevToolsOpen,
        devToolsClose: @escaping OwlBrowserRuntimeBoolOut,
        devToolsEvaluateJavaScript: @escaping OwlBrowserRuntimeStringInputResult,
        eventPoll: @escaping OwlBrowserRuntimePollEvents,
        freeBuffer: @escaping OwlBrowserRuntimeFreeBuffer
    ) {
        self.globalInit = globalInit
        self.sessionCreate = sessionCreate
        self.sessionDestroy = sessionDestroy
        self.sessionHostPID = sessionHostPID
        self.shellExecuteJavaScript = shellExecuteJavaScript
        self.sessionSetClient = sessionSetClient
        self.sessionBindProfile = sessionBindProfile
        self.sessionBindWebView = sessionBindWebView
        self.sessionBindInput = sessionBindInput
        self.sessionBindSurfaceTree = sessionBindSurfaceTree
        self.sessionBindNativeSurfaceHost = sessionBindNativeSurfaceHost
        self.sessionBindDevToolsHost = sessionBindDevToolsHost
        self.sessionFlush = sessionFlush
        self.profileGetPath = profileGetPath
        self.webViewNavigate = webViewNavigate
        self.webViewResize = webViewResize
        self.webViewSetFocus = webViewSetFocus
        self.inputSendMouse = inputSendMouse
        self.inputSendKey = inputSendKey
        self.surfaceTreeCaptureSurfaceJSON = surfaceTreeCaptureSurfaceJSON
        self.surfaceTreeGetJSON = surfaceTreeGetJSON
        self.nativeSurfaceAccept = nativeSurfaceAccept
        self.nativeSurfaceCancel = nativeSurfaceCancel
        self.nativeSurfaceSelectFilePickerFilesJSON = nativeSurfaceSelectFilePickerFilesJSON
        self.nativeSurfaceCancelFilePicker = nativeSurfaceCancelFilePicker
        self.devToolsOpen = devToolsOpen
        self.devToolsClose = devToolsClose
        self.devToolsEvaluateJavaScript = devToolsEvaluateJavaScript
        self.eventPoll = eventPoll
        self.freeBuffer = freeBuffer
    }
}
