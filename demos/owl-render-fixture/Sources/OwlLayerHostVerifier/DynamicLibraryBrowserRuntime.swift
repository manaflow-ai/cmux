import Darwin
import Foundation
import OwlBrowserCore

final class DynamicLibraryBrowserRuntime: OwlCBrowserRuntime {
    private let handle: UnsafeMutableRawPointer

    override public var runtimeDescription: String {
        "DynamicLibraryBrowserRuntime verifier adapter over OwlCBrowserRuntime generated Mojo pipe bindings"
    }

    init(path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw OwlBrowserError.bridge("dlopen failed for \(path): \(dlerrorString())")
        }
        let symbols: OwlBrowserRuntimeSymbols
        do {
            symbols = try loadRuntimeSymbols(handle)
        } catch {
            dlclose(handle)
            throw error
        }
        self.handle = handle
        super.init(symbols: symbols)
    }

    deinit {
        dlclose(handle)
    }
}

private func loadRuntimeSymbols(_ handle: UnsafeMutableRawPointer) throws -> OwlBrowserRuntimeSymbols {
    OwlBrowserRuntimeSymbols(
        globalInit: try loadSymbol(handle, "owl_fresh_mojo_global_init", as: OwlBrowserRuntimeGlobalInit.self),
        sessionCreate: try loadSymbol(handle, "owl_fresh_mojo_session_create", as: OwlBrowserRuntimeSessionCreate.self),
        sessionDestroy: try loadSymbol(handle, "owl_fresh_mojo_session_destroy", as: OwlBrowserRuntimeSessionDestroy.self),
        sessionHostPID: try loadSymbol(handle, "owl_fresh_mojo_session_host_pid", as: OwlBrowserRuntimeHostPID.self),
        shellExecuteJavaScript: try loadSymbol(
            handle,
            "owl_fresh_mojo_shell_execute_javascript",
            as: OwlBrowserRuntimeStringInputResult.self
        ),
        sessionSetClient: try loadSymbol(
            handle,
            "owl_fresh_mojo_session_set_client",
            as: OwlBrowserRuntimeVoidUInt64.self
        ),
        sessionBindProfile: try loadSymbol(
            handle,
            "owl_fresh_mojo_session_bind_profile",
            as: OwlBrowserRuntimeVoidUInt64.self
        ),
        sessionBindWebView: try loadSymbol(
            handle,
            "owl_fresh_mojo_session_bind_web_view",
            as: OwlBrowserRuntimeVoidUInt64.self
        ),
        sessionBindInput: try loadSymbol(
            handle,
            "owl_fresh_mojo_session_bind_input",
            as: OwlBrowserRuntimeVoidUInt64.self
        ),
        sessionBindSurfaceTree: try loadSymbol(
            handle,
            "owl_fresh_mojo_session_bind_surface_tree",
            as: OwlBrowserRuntimeVoidUInt64.self
        ),
        sessionBindNativeSurfaceHost: try loadSymbol(
            handle,
            "owl_fresh_mojo_session_bind_native_surface_host",
            as: OwlBrowserRuntimeVoidUInt64.self
        ),
        sessionBindDevToolsHost: try loadSymbol(
            handle,
            "owl_fresh_mojo_session_bind_devtools_host",
            as: OwlBrowserRuntimeVoidUInt64.self
        ),
        sessionFlush: try loadSymbol(handle, "owl_fresh_mojo_session_flush", as: OwlBrowserRuntimeBoolOut.self),
        profileGetPath: try loadSymbol(handle, "owl_fresh_mojo_profile_get_path", as: OwlBrowserRuntimeStringOut.self),
        webViewNavigate: try loadSymbol(handle, "owl_fresh_mojo_web_view_navigate", as: OwlBrowserRuntimeVoidString.self),
        webViewResize: try loadSymbol(handle, "owl_fresh_mojo_web_view_resize", as: OwlBrowserRuntimeWebViewResize.self),
        webViewSetFocus: try loadSymbol(handle, "owl_fresh_mojo_web_view_set_focus", as: OwlBrowserRuntimeVoidBool.self),
        inputSendMouse: try loadSymbol(handle, "owl_fresh_mojo_input_send_mouse", as: OwlBrowserRuntimeInputSendMouse.self),
        inputSendKey: try loadSymbol(handle, "owl_fresh_mojo_input_send_key", as: OwlBrowserRuntimeInputSendKey.self),
        surfaceTreeCaptureSurfaceJSON: try loadSymbol(
            handle,
            "owl_fresh_mojo_surface_tree_capture_surface_json",
            as: OwlBrowserRuntimeStringOut.self
        ),
        surfaceTreeGetJSON: try loadSymbol(
            handle,
            "owl_fresh_mojo_surface_tree_get_json",
            as: OwlBrowserRuntimeStringOut.self
        ),
        nativeSurfaceAccept: try loadSymbol(
            handle,
            "owl_fresh_mojo_native_surface_accept_active_popup_menu_item",
            as: OwlBrowserRuntimeNativeSurfaceAccept.self
        ),
        nativeSurfaceCancel: try loadSymbol(
            handle,
            "owl_fresh_mojo_native_surface_cancel_active_popup",
            as: OwlBrowserRuntimeBoolOut.self
        ),
        nativeSurfaceSelectFilePickerFilesJSON: try loadSymbol(
            handle,
            "owl_fresh_mojo_native_surface_select_active_file_picker_files_json",
            as: OwlBrowserRuntimeStringInputBoolOut.self
        ),
        nativeSurfaceCancelFilePicker: try loadSymbol(
            handle,
            "owl_fresh_mojo_native_surface_cancel_active_file_picker",
            as: OwlBrowserRuntimeBoolOut.self
        ),
        devToolsOpen: try loadSymbol(
            handle,
            "owl_fresh_mojo_devtools_open",
            as: OwlBrowserRuntimeDevToolsOpen.self
        ),
        devToolsClose: try loadSymbol(
            handle,
            "owl_fresh_mojo_devtools_close",
            as: OwlBrowserRuntimeBoolOut.self
        ),
        devToolsEvaluateJavaScript: try loadSymbol(
            handle,
            "owl_fresh_mojo_devtools_evaluate_javascript",
            as: OwlBrowserRuntimeStringInputResult.self
        ),
        eventPoll: try loadSymbol(handle, "owl_fresh_mojo_poll_events", as: OwlBrowserRuntimePollEvents.self),
        freeBuffer: try loadSymbol(handle, "owl_fresh_mojo_free_buffer", as: OwlBrowserRuntimeFreeBuffer.self)
    )
}

private func loadSymbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, as _: T.Type) throws -> T {
    guard let symbol = dlsym(handle, name) else {
        throw OwlBrowserError.bridge("missing symbol \(name): \(dlerrorString())")
    }
    return unsafeBitCast(symbol, to: T.self)
}

private func dlerrorString() -> String {
    guard let error = dlerror() else {
        return "unknown dynamic loader error"
    }
    return String(cString: error)
}
