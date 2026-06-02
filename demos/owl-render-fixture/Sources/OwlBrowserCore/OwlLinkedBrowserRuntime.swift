import Foundation

#if OWL_LINKED_BROWSER_RUNTIME
public final class OwlLinkedBrowserRuntime: OwlCBrowserRuntime {
    public override var runtimeDescription: String {
        "OwlLinkedBrowserRuntime over directly linked Chromium Mojo symbols"
    }

    public init() {
        super.init(symbols: OwlLinkedBrowserRuntimeSymbols.symbols)
    }
}

private enum OwlLinkedBrowserRuntimeSymbols {
    static let symbols = OwlBrowserRuntimeSymbols(
        globalInit: owl_fresh_mojo_global_init,
        sessionCreate: owl_fresh_mojo_session_create,
        sessionDestroy: owl_fresh_mojo_session_destroy,
        sessionHostPID: owl_fresh_mojo_session_host_pid,
        shellExecuteJavaScript: owl_fresh_mojo_shell_execute_javascript,
        sessionSetClient: owl_fresh_mojo_session_set_client,
        sessionBindProfile: owl_fresh_mojo_session_bind_profile,
        sessionBindWebView: owl_fresh_mojo_session_bind_web_view,
        sessionBindInput: owl_fresh_mojo_session_bind_input,
        sessionBindSurfaceTree: owl_fresh_mojo_session_bind_surface_tree,
        sessionBindNativeSurfaceHost: owl_fresh_mojo_session_bind_native_surface_host,
        sessionBindDevToolsHost: owl_fresh_mojo_session_bind_devtools_host,
        sessionFlush: owl_fresh_mojo_session_flush,
        profileGetPath: owl_fresh_mojo_profile_get_path,
        webViewNavigate: owl_fresh_mojo_web_view_navigate,
        webViewResize: owl_fresh_mojo_web_view_resize,
        webViewSetFocus: owl_fresh_mojo_web_view_set_focus,
        inputSendMouse: owl_fresh_mojo_input_send_mouse,
        inputSendKey: owl_fresh_mojo_input_send_key,
        surfaceTreeCaptureSurfaceJSON: owl_fresh_mojo_surface_tree_capture_surface_json,
        surfaceTreeGetJSON: owl_fresh_mojo_surface_tree_get_json,
        nativeSurfaceAccept: owl_fresh_mojo_native_surface_accept_active_popup_menu_item,
        nativeSurfaceCancel: owl_fresh_mojo_native_surface_cancel_active_popup,
        nativeSurfaceSelectFilePickerFilesJSON: owl_fresh_mojo_native_surface_select_active_file_picker_files_json,
        nativeSurfaceCancelFilePicker: owl_fresh_mojo_native_surface_cancel_active_file_picker,
        devToolsOpen: owl_fresh_mojo_devtools_open,
        devToolsClose: owl_fresh_mojo_devtools_close,
        devToolsEvaluateJavaScript: owl_fresh_mojo_devtools_evaluate_javascript,
        eventPoll: owl_fresh_mojo_poll_events,
        freeBuffer: owl_fresh_mojo_free_buffer
    )
}

@_silgen_name("owl_fresh_mojo_global_init")
private func owl_fresh_mojo_global_init() -> Int32

@_silgen_name("owl_fresh_mojo_session_create")
private func owl_fresh_mojo_session_create(
    _ chromiumHost: UnsafePointer<CChar>,
    _ initialURL: UnsafePointer<CChar>?,
    _ userDataDirectory: UnsafePointer<CChar>?,
    _ callback: OwlFreshEventCallback?,
    _ userData: UnsafeMutableRawPointer?
) -> OpaquePointer?

@_silgen_name("owl_fresh_mojo_session_destroy")
private func owl_fresh_mojo_session_destroy(_ session: OpaquePointer?)

@_silgen_name("owl_fresh_mojo_session_host_pid")
private func owl_fresh_mojo_session_host_pid(_ session: OpaquePointer?) -> Int32

@_silgen_name("owl_fresh_mojo_shell_execute_javascript")
private func owl_fresh_mojo_shell_execute_javascript(
    _ session: OpaquePointer?,
    _ script: UnsafePointer<CChar>?,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_session_set_client")
private func owl_fresh_mojo_session_set_client(
    _ session: OpaquePointer?,
    _ client: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_session_bind_profile")
private func owl_fresh_mojo_session_bind_profile(
    _ session: OpaquePointer?,
    _ profile: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_session_bind_web_view")
private func owl_fresh_mojo_session_bind_web_view(
    _ session: OpaquePointer?,
    _ webView: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_session_bind_input")
private func owl_fresh_mojo_session_bind_input(
    _ session: OpaquePointer?,
    _ input: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_session_bind_surface_tree")
private func owl_fresh_mojo_session_bind_surface_tree(
    _ session: OpaquePointer?,
    _ surfaceTree: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_session_bind_native_surface_host")
private func owl_fresh_mojo_session_bind_native_surface_host(
    _ session: OpaquePointer?,
    _ nativeSurfaceHost: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_session_bind_devtools_host")
private func owl_fresh_mojo_session_bind_devtools_host(
    _ session: OpaquePointer?,
    _ devToolsHost: UInt64,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_session_flush")
private func owl_fresh_mojo_session_flush(
    _ session: OpaquePointer?,
    _ ok: UnsafeMutablePointer<Bool>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_profile_get_path")
private func owl_fresh_mojo_profile_get_path(
    _ session: OpaquePointer?,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_web_view_navigate")
private func owl_fresh_mojo_web_view_navigate(
    _ session: OpaquePointer?,
    _ url: UnsafePointer<CChar>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_web_view_resize")
private func owl_fresh_mojo_web_view_resize(
    _ session: OpaquePointer?,
    _ width: UInt32,
    _ height: UInt32,
    _ scale: Float,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_web_view_set_focus")
private func owl_fresh_mojo_web_view_set_focus(
    _ session: OpaquePointer?,
    _ focused: Bool,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_input_send_mouse")
private func owl_fresh_mojo_input_send_mouse(
    _ session: OpaquePointer?,
    _ kind: UInt32,
    _ x: Float,
    _ y: Float,
    _ button: UInt32,
    _ clickCount: UInt32,
    _ deltaX: Float,
    _ deltaY: Float,
    _ modifiers: UInt32,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_input_send_key")
private func owl_fresh_mojo_input_send_key(
    _ session: OpaquePointer?,
    _ keyDown: Bool,
    _ keyCode: UInt32,
    _ text: UnsafePointer<CChar>?,
    _ modifiers: UInt32,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_surface_tree_capture_surface_json")
private func owl_fresh_mojo_surface_tree_capture_surface_json(
    _ session: OpaquePointer?,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_surface_tree_get_json")
private func owl_fresh_mojo_surface_tree_get_json(
    _ session: OpaquePointer?,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_native_surface_accept_active_popup_menu_item")
private func owl_fresh_mojo_native_surface_accept_active_popup_menu_item(
    _ session: OpaquePointer?,
    _ index: UInt32,
    _ ok: UnsafeMutablePointer<Bool>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_native_surface_cancel_active_popup")
private func owl_fresh_mojo_native_surface_cancel_active_popup(
    _ session: OpaquePointer?,
    _ ok: UnsafeMutablePointer<Bool>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_native_surface_select_active_file_picker_files_json")
private func owl_fresh_mojo_native_surface_select_active_file_picker_files_json(
    _ session: OpaquePointer?,
    _ pathsJSON: UnsafePointer<CChar>?,
    _ ok: UnsafeMutablePointer<Bool>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_native_surface_cancel_active_file_picker")
private func owl_fresh_mojo_native_surface_cancel_active_file_picker(
    _ session: OpaquePointer?,
    _ ok: UnsafeMutablePointer<Bool>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_devtools_open")
private func owl_fresh_mojo_devtools_open(
    _ session: OpaquePointer?,
    _ mode: UInt32,
    _ ok: UnsafeMutablePointer<Bool>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_devtools_close")
private func owl_fresh_mojo_devtools_close(
    _ session: OpaquePointer?,
    _ ok: UnsafeMutablePointer<Bool>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_devtools_evaluate_javascript")
private func owl_fresh_mojo_devtools_evaluate_javascript(
    _ session: OpaquePointer?,
    _ script: UnsafePointer<CChar>?,
    _ result: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_silgen_name("owl_fresh_mojo_poll_events")
private func owl_fresh_mojo_poll_events(_ milliseconds: UInt32)

@_silgen_name("owl_fresh_mojo_free_buffer")
private func owl_fresh_mojo_free_buffer(_ pointer: UnsafeMutableRawPointer?)
#endif
