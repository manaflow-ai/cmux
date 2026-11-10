//! C ABI v1 of cmux Computer Use (`include/cmux_computer_use.h`), loaded by
//! the macOS Computer Use worker in cmux Remote.

#![allow(clippy::missing_safety_doc)]

use std::sync::Arc;
use std::time::Duration;

use cmux_computer_use::cursor::{CursorEvent, CursorSink};
use cmux_computer_use::desktop::{
    CaptureTarget, DResult, DesktopError, HostServices, Point, RawFrame,
};
use cmux_computer_use::engine::{
    Answer, Approver, CallContext, Engine, EngineParts, PersonActivity, Question,
};
use cmux_computer_use::policy::{OriginKind, PolicyConfig};
use cmux_computer_use::tools;
use serde_json::{Value, json};

pub const ABI_VERSION: u32 = 1;

#[repr(C)]
pub struct CmuxCuBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl CmuxCuBuffer {
    fn from_string(s: String) -> Self {
        let mut bytes = s.into_bytes().into_boxed_slice();
        let out = CmuxCuBuffer { data: bytes.as_mut_ptr(), len: bytes.len() };
        std::mem::forget(bytes);
        out
    }
    fn empty() -> Self {
        CmuxCuBuffer { data: std::ptr::null_mut(), len: 0 }
    }
}

#[repr(C)]
pub struct CmuxCuFrame {
    pub width: u32,
    pub height: u32,
    pub rgba: *const u8,
    pub scale: f64,
    pub origin_x: f64,
    pub origin_y: f64,
    pub host_token: *mut std::ffi::c_void,
}

type CaptureFn = unsafe extern "C" fn(
    *mut std::ffi::c_void,
    *const u8,
    usize,
    *mut CmuxCuFrame,
    *mut u8,
    usize,
) -> i32;
type ReleaseFn = unsafe extern "C" fn(*mut std::ffi::c_void, *mut std::ffi::c_void);
type CursorFn = unsafe extern "C" fn(*mut std::ffi::c_void, *const u8, usize);
type AskFn = unsafe extern "C" fn(*mut std::ffi::c_void, *const u8, usize) -> i32;
type WaitIdleFn = unsafe extern "C" fn(*mut std::ffi::c_void, u64) -> bool;
type PermissionFn = unsafe extern "C" fn(*mut std::ffi::c_void, *const u8, usize) -> i32;
type CaptureAppsFn = unsafe extern "C" fn(*mut std::ffi::c_void, *mut u8, usize, *mut usize) -> i32;
type PersonEventsFn = unsafe extern "C" fn(*mut std::ffi::c_void) -> i64;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CmuxCuHost {
    pub struct_size: u32,
    pub context: *mut std::ffi::c_void,
    pub capture: Option<CaptureFn>,
    pub release_frame: Option<ReleaseFn>,
    pub cursor: Option<CursorFn>,
    pub ask: Option<AskFn>,
    pub wait_idle: Option<WaitIdleFn>,
    pub request_permission: Option<PermissionFn>,
    pub capture_apps: Option<CaptureAppsFn>,
    /// Added after the first release of the table: read only when the
    /// host's `struct_size` covers it ([`CmuxCuHost::copy_from`]).
    pub person_events: Option<PersonEventsFn>,
}

impl CmuxCuHost {
    /// Copies the host's table: the fields its `struct_size` covers, the
    /// rest left `None`, so a host built against an older header still works.
    ///
    /// # Safety
    /// `host` is non-null and points to at least `struct_size` readable bytes
    /// (and at least the size of `struct_size` itself).
    unsafe fn copy_from(host: *const CmuxCuHost) -> CmuxCuHost {
        // SAFETY: every field is an integer, a pointer or an Option of a fn
        // pointer, for which all-zero bytes are valid (0, null, None).
        let mut out: CmuxCuHost = unsafe { std::mem::zeroed() };
        // SAFETY: the caller promises struct_size is readable.
        let declared = unsafe { std::ptr::addr_of!((*host).struct_size).read_unaligned() } as usize;
        let len = declared.min(size_of::<CmuxCuHost>());
        // SAFETY: len bytes are readable from host (caller) and writable in out.
        unsafe {
            std::ptr::copy_nonoverlapping(
                host.cast::<u8>(),
                std::ptr::addr_of_mut!(out).cast::<u8>(),
                len,
            );
        }
        out
    }
}

/// The host's callbacks. The host promises its context outlives the engine
/// and that the callbacks are thread-safe (header contract).
#[derive(Clone, Copy)]
struct Host(CmuxCuHost);
unsafe impl Send for Host {}
unsafe impl Sync for Host {}

impl HostServices for Host {
    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        let request = match target {
            CaptureTarget::Window(id) => json!({"window": id}),
            CaptureTarget::Display(d) => json!({"display": d}),
        };
        self.capture_request(&request.to_string())
    }

    fn capture_display_excluding(
        &self,
        display: Option<&str>,
        exclude_pids: &[u32],
    ) -> DResult<RawFrame> {
        self.capture_request(&json!({"display": display, "exclude_pids": exclude_pids}).to_string())
    }

    fn capture_apps(&self) -> DResult<Vec<cmux_computer_use::desktop::App>> {
        let Some(f) = self.0.capture_apps else {
            return Err(DesktopError::Unsupported("the worker lists no capture apps".into()));
        };
        let mut buffer = vec![0u8; 64 * 1024];
        for _ in 0..3 {
            let mut len = 0usize;
            // SAFETY: header contract: writes at most `cap` bytes to `out`.
            let status = unsafe { f(self.0.context, buffer.as_mut_ptr(), buffer.len(), &mut len) };
            match status {
                0 => {
                    let bytes = buffer.get(..len.min(buffer.len())).unwrap_or_default();
                    let rows: Vec<Value> = serde_json::from_slice(bytes)
                        .map_err(|e| DesktopError::Failed(format!("capture apps: {e}")))?;
                    return Ok(rows
                        .iter()
                        .filter_map(|r| {
                            let pid = r
                                .get("pid")?
                                .as_u64()
                                .filter(|p| *p > 0 && *p <= u32::MAX as u64)?
                                as u32;
                            let id = r.get("id").and_then(Value::as_str).unwrap_or_default();
                            let name = r.get("name").and_then(Value::as_str).unwrap_or_default();
                            Some(cmux_computer_use::desktop::App {
                                id: id.to_string(),
                                name: name.to_string(),
                                pid,
                                frontmost: false,
                                hidden: false,
                            })
                        })
                        .collect());
                }
                2 if len > buffer.len() && len <= 16 << 20 => buffer.resize(len, 0),
                _ => {
                    return Err(DesktopError::Failed(
                        "the worker could not list the capture's apps".into(),
                    ));
                }
            }
        }
        Err(DesktopError::Failed("the capture's app list kept growing".into()))
    }

    fn request_permission(&self, which: &str) -> DResult<()> {
        self.request_permission_named(which)
    }
}

impl Host {
    fn capture_request(&self, request: &str) -> DResult<RawFrame> {
        let Some(capture) = self.0.capture else {
            return Err(DesktopError::Unsupported("the worker supplies no capture".into()));
        };
        let mut frame = CmuxCuFrame {
            width: 0,
            height: 0,
            rgba: std::ptr::null(),
            scale: 1.0,
            origin_x: 0.0,
            origin_y: 0.0,
            host_token: std::ptr::null_mut(),
        };
        let mut error = [0u8; 512];
        // SAFETY: the header's contract: valid pointers for the call's duration.
        let status = unsafe {
            capture(
                self.0.context,
                request.as_ptr(),
                request.len(),
                &mut frame,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if status != 0 {
            let end = error.iter().position(|b| *b == 0).unwrap_or(error.len());
            let message = String::from_utf8_lossy(&error[..end]).into_owned();
            return Err(if message.contains("permission") {
                DesktopError::PermissionMissing("screen_capture".into())
            } else {
                DesktopError::Failed(message)
            });
        }
        let len = (frame.width as usize) * (frame.height as usize) * 4;
        let rgba = if frame.rgba.is_null() || len == 0 {
            Vec::new()
        } else {
            // SAFETY: the host keeps `len` bytes alive until release_frame.
            unsafe { std::slice::from_raw_parts(frame.rgba, len) }.to_vec()
        };
        if let Some(release) = self.0.release_frame {
            // SAFETY: token from this capture.
            unsafe { release(self.0.context, frame.host_token) };
        }
        Ok(RawFrame {
            width: frame.width,
            height: frame.height,
            rgba,
            scale: frame.scale,
            origin: Point { x: frame.origin_x, y: frame.origin_y },
        })
    }

    fn request_permission_named(&self, which: &str) -> DResult<()> {
        let Some(f) = self.0.request_permission else {
            return Err(DesktopError::Unsupported("no permission prompt here".into()));
        };
        // SAFETY: valid for the call.
        match unsafe { f(self.0.context, which.as_ptr(), which.len()) } {
            0 => Ok(()),
            _ => Err(DesktopError::Failed(format!("could not ask for {which}"))),
        }
    }
}

impl CursorSink for Host {
    fn show(&self, event: CursorEvent) {
        if let Some(f) = self.0.cursor
            && let Ok(text) = serde_json::to_string(&event)
        {
            // SAFETY: valid for the call.
            unsafe { f(self.0.context, text.as_ptr(), text.len()) };
        }
    }
}

impl Approver for Host {
    fn ask(&self, q: &Question) -> Answer {
        let Some(f) = self.0.ask else { return Answer::Unavailable };
        let text = json!({
            "session": q.session, "agent": q.agent,
            "app": {"id": q.app.id, "name": q.app.name},
            "remember": q.remember, "from_machine": q.from_machine,
        })
        .to_string();
        // SAFETY: valid for the call.
        match unsafe { f(self.0.context, text.as_ptr(), text.len()) } {
            1 => Answer::AllowOnce,
            2 => Answer::AllowSession,
            3 => Answer::AlwaysAllow,
            4 => Answer::Deny,
            5 => Answer::Never,
            _ => Answer::Unavailable,
        }
    }
}

impl PersonActivity for Host {
    fn wait_idle(&self, limit: Duration) -> bool {
        match self.0.wait_idle {
            // SAFETY: plain call.
            Some(f) => unsafe { f(self.0.context, limit.as_millis() as u64) },
            None => true,
        }
    }

    fn input_count(&self) -> Option<u64> {
        let f = self.0.person_events?;
        // SAFETY: plain call.
        let n = unsafe { f(self.0.context) };
        u64::try_from(n).ok()
    }
}

pub struct CmuxCuEngine {
    engine: Arc<Engine>,
}

/// A serving agent socket (`cmux_cu_serve`).
pub struct CmuxCuServer {
    server: Option<cmux_computer_use::server::Server>,
}

unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
    if ptr.is_null() || len == 0 {
        &[]
    } else {
        // SAFETY: caller passes a valid (ptr, len).
        unsafe { std::slice::from_raw_parts(ptr, len) }
    }
}

unsafe fn text<'a>(ptr: *const u8, len: usize) -> &'a str {
    // SAFETY: forwarded.
    std::str::from_utf8(unsafe { bytes(ptr, len) }).unwrap_or("")
}

fn set_error(error: *mut CmuxCuBuffer, message: String) {
    if !error.is_null() {
        // SAFETY: caller-provided out pointer.
        unsafe { *error = CmuxCuBuffer::from_string(message) };
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_cu_abi_version() -> u32 {
    ABI_VERSION
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_engine_create(
    config_json: *const u8,
    config_len: usize,
    state_dir: *const u8,
    state_dir_len: usize,
    machine_name: *const u8,
    machine_name_len: usize,
    host: *const CmuxCuHost,
    error: *mut CmuxCuBuffer,
) -> *mut CmuxCuEngine {
    // SAFETY: header contract.
    let config_bytes = unsafe { bytes(config_json, config_len) };
    let config: PolicyConfig = if config_bytes.is_empty() {
        PolicyConfig::default()
    } else {
        match serde_json::from_slice(config_bytes) {
            Ok(c) => c,
            Err(e) => {
                set_error(error, format!("bad config: {e}"));
                return std::ptr::null_mut();
            }
        }
    };
    if host.is_null() {
        set_error(error, "host is required".into());
        return std::ptr::null_mut();
    }
    // SAFETY: non-null, caller-provided; the fields its struct_size covers are copied.
    let host = Host(unsafe { CmuxCuHost::copy_from(host) });
    let host_arc: Arc<Host> = Arc::new(host);
    #[cfg(target_os = "macos")]
    let desktop: Arc<dyn cmux_computer_use::Desktop> =
        Arc::new(cmux_computer_use::platform::macos::MacDesktop::new(Some(
            host_arc.clone() as Arc<dyn HostServices>
        )));
    #[cfg(not(target_os = "macos"))]
    let desktop: Arc<dyn cmux_computer_use::Desktop> = match cmux_computer_use::platform::open() {
        Ok(d) => d,
        Err(e) => {
            set_error(error, e);
            return std::ptr::null_mut();
        }
    };
    // SAFETY: header contract.
    let dir = unsafe { text(state_dir, state_dir_len) };
    let mut parts = EngineParts::new(desktop);
    parts.config = config;
    parts.state_dir = (!dir.is_empty()).then(|| std::path::PathBuf::from(dir));
    parts.cursor = host_arc.clone();
    parts.approver = host_arc.clone();
    parts.takeover = host_arc;
    // SAFETY: header contract.
    parts.machine_name = unsafe { text(machine_name, machine_name_len) }.to_string();
    Box::into_raw(Box::new(CmuxCuEngine { engine: Arc::new(Engine::new(parts)) }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_engine_destroy(engine: *mut CmuxCuEngine) {
    if !engine.is_null() {
        // SAFETY: from cmux_cu_engine_create.
        drop(unsafe { Box::from_raw(engine) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_engine_set_config(
    engine: *mut CmuxCuEngine,
    config_json: *const u8,
    config_len: usize,
    error: *mut CmuxCuBuffer,
) -> i32 {
    // SAFETY: from create.
    let Some(engine) = (unsafe { engine.as_ref() }) else { return 1 };
    // SAFETY: header contract.
    match serde_json::from_slice::<PolicyConfig>(unsafe { bytes(config_json, config_len) }) {
        Ok(c) => {
            engine.engine.set_config(c);
            0
        }
        Err(e) => {
            set_error(error, format!("bad config: {e}"));
            1
        }
    }
}

/// Parses a call request into its context.
pub fn parse_request(v: &Value) -> Result<(CallContext, String, Value), String> {
    let name = v.get("name").and_then(Value::as_str).ok_or("name is required")?.to_string();
    let session = v.get("session").and_then(Value::as_str).unwrap_or("default").to_string();
    let origin = match v.get("origin") {
        Some(o) if !o.is_null() => {
            serde_json::from_value::<OriginKind>(o.clone()).map_err(|e| e.to_string())?
        }
        _ => OriginKind::Local,
    };
    Ok((
        CallContext {
            session,
            label: v.get("label").and_then(Value::as_str).unwrap_or("Agent").to_string(),
            call_id: v.get("call_id").and_then(Value::as_str).map(str::to_string),
            origin,
        },
        name,
        v.get("arguments").cloned().unwrap_or(json!({})),
    ))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_engine_call(
    engine: *mut CmuxCuEngine,
    request_json: *const u8,
    request_len: usize,
) -> CmuxCuBuffer {
    // SAFETY: from create.
    let Some(engine) = (unsafe { engine.as_ref() }) else { return CmuxCuBuffer::empty() };
    // SAFETY: header contract.
    let out = match serde_json::from_slice::<Value>(unsafe { bytes(request_json, request_len) })
        .map_err(|e| e.to_string())
        .and_then(|v| parse_request(&v))
    {
        // A panic must not unwind into Swift (undefined behavior) or abort
        // cmux Remote: the call fails instead.
        Ok((ctx, name, args)) => std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            engine.engine.call(&ctx, &name, &args)
        }))
        .unwrap_or_else(|_| {
            cmux_computer_use::ToolOutput::error("failed", "Computer Use failed on this call")
        }),
        Err(e) => cmux_computer_use::ToolOutput::error("invalid_request", e),
    };
    CmuxCuBuffer::from_string(out.to_json().to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_engine_end_session(
    engine: *mut CmuxCuEngine,
    session: *const u8,
    session_len: usize,
) {
    // SAFETY: from create / header contract.
    if let Some(engine) = unsafe { engine.as_ref() } {
        engine.engine.end_session(unsafe { text(session, session_len) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_engine_saved_approvals(engine: *mut CmuxCuEngine) -> CmuxCuBuffer {
    // SAFETY: from create.
    let Some(engine) = (unsafe { engine.as_ref() }) else { return CmuxCuBuffer::empty() };
    CmuxCuBuffer::from_string(
        serde_json::to_string(&engine.engine.sessions().saved()).unwrap_or_default(),
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_engine_edit_approvals(
    engine: *mut CmuxCuEngine,
    action: *const u8,
    action_len: usize,
    app_id: *const u8,
    app_id_len: usize,
) -> i32 {
    // SAFETY: from create / header contract.
    let Some(engine) = (unsafe { engine.as_ref() }) else { return 1 };
    let action = unsafe { text(action, action_len) };
    let app = unsafe { text(app_id, app_id_len) }.to_string();
    let sessions = engine.engine.sessions();
    match action {
        "forget" => sessions.update_saved(|s| s.forget(&app)),
        "always" => sessions.update_saved(|s| s.set_always(&app)),
        "never" => sessions.update_saved(|s| s.set_never(&app)),
        "revoke_sessions" => sessions.revoke_all(None),
        _ => return 1,
    }
    0
}

/// Serves `engine` on the agent socket (`cmux-computer-use-v1`, the same Rust
/// server the Linux and Windows workers run): a Unix socket at
/// `socket_path` (0600, its directory 0700), admitting this user's processes
/// that present `secret_hex` (at least 16 bytes). NULL with error filled on
/// failure. The server keeps the engine alive; stop it before destroying the
/// engine's host context.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_serve(
    engine: *mut CmuxCuEngine,
    socket_path: *const u8,
    socket_path_len: usize,
    secret_hex: *const u8,
    secret_hex_len: usize,
    error: *mut CmuxCuBuffer,
) -> *mut CmuxCuServer {
    // SAFETY: from create.
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_error(error, "engine is required".into());
        return std::ptr::null_mut();
    };
    // SAFETY: header contract.
    let path = unsafe { text(socket_path, socket_path_len) };
    // SAFETY: header contract.
    let Some(secret) = cmux_computer_use::wire::unhex(unsafe { text(secret_hex, secret_hex_len) })
    else {
        set_error(error, "the secret is not hex".into());
        return std::ptr::null_mut();
    };
    if path.is_empty() {
        set_error(error, "socket_path is required".into());
        return std::ptr::null_mut();
    }
    match cmux_computer_use::server::serve(Arc::clone(&engine.engine), path, &secret) {
        Ok(server) => Box::into_raw(Box::new(CmuxCuServer { server: Some(server) })),
        Err(e) => {
            set_error(error, format!("cannot serve {path}: {e}"));
            std::ptr::null_mut()
        }
    }
}

/// Stops serving: no new connections, live ones closed, the socket file
/// removed. Calls already running finish first. Frees `server`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_serve_stop(server: *mut CmuxCuServer) {
    if !server.is_null() {
        // SAFETY: from cmux_cu_serve, freed once.
        let mut server = unsafe { Box::from_raw(server) };
        if let Some(server) = server.server.take() {
            server.stop();
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_cu_tools_list() -> CmuxCuBuffer {
    let mut list = tools::mcp_list();
    list["instructions"] = json!(tools::INSTRUCTIONS);
    CmuxCuBuffer::from_string(list.to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_cu_buffer_free(buffer: CmuxCuBuffer) {
    if !buffer.data.is_null() {
        // SAFETY: allocated by from_string as a boxed slice of `len`.
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.data, buffer.len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_requests_with_remote_origin() {
        let (ctx, name, args) = parse_request(&json!({
            "name": "click", "arguments": {"x": 1}, "session": "s", "label": "Codex",
            "call_id": "c", "origin": {"kind": "remote", "machine": "mini", "same_account": true}
        }))
        .unwrap();
        assert_eq!(name, "click");
        assert_eq!(args["x"], 1);
        assert_eq!(ctx.origin, OriginKind::Remote { machine: "mini".into(), same_account: true });
        assert!(parse_request(&json!({})).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn serve_and_stop_through_the_c_abi() {
        use std::io::{BufRead, BufReader, Write};
        let desktop: Arc<dyn cmux_computer_use::Desktop> =
            Arc::new(cmux_computer_use::desktop::fake::FakeDesktop::standard());
        let engine = Box::into_raw(Box::new(CmuxCuEngine {
            engine: Arc::new(Engine::new(EngineParts::new(desktop))),
        }));
        let dir = format!("/tmp/cuffi{}", std::process::id());
        let path = format!("{dir}/s.sock");
        let secret = "ab".repeat(32);
        let mut error = CmuxCuBuffer::empty();
        // SAFETY: valid pointers for the call.
        let server = unsafe {
            cmux_cu_serve(
                engine,
                path.as_ptr(),
                path.len(),
                secret.as_ptr(),
                secret.len(),
                &mut error,
            )
        };
        assert!(!server.is_null());
        let mut stream = std::os::unix::net::UnixStream::connect(&path).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        writeln!(stream, "{}", json!({"secret": secret})).unwrap();
        writeln!(stream, "{}", json!({"id": 1, "method": "status"})).unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        assert!(line.contains("\"ok\":true"), "{line}");
        line.clear();
        reader.read_line(&mut line).unwrap();
        assert!(line.contains("\"mode\":\"fullAccess\""), "{line}");
        // SAFETY: from cmux_cu_serve / create.
        unsafe {
            cmux_cu_serve_stop(server);
            cmux_cu_engine_destroy(engine);
        }
        assert!(!std::path::Path::new(&path).exists());
        // A short secret is refused.
        let short = "ab";
        let engine = Box::into_raw(Box::new(CmuxCuEngine {
            engine: Arc::new(Engine::new(EngineParts::new(Arc::new(
                cmux_computer_use::desktop::fake::FakeDesktop::standard(),
            )))),
        }));
        // SAFETY: valid pointers for the call.
        let server = unsafe {
            cmux_cu_serve(
                engine,
                path.as_ptr(),
                path.len(),
                short.as_ptr(),
                short.len(),
                &mut error,
            )
        };
        assert!(server.is_null() && !error.data.is_null());
        // SAFETY: from the library.
        unsafe {
            cmux_cu_buffer_free(error);
            cmux_cu_engine_destroy(engine);
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn buffers_round_trip() {
        let b = cmux_cu_tools_list();
        // SAFETY: from the library.
        let s = unsafe { std::str::from_utf8(std::slice::from_raw_parts(b.data, b.len)) }
            .unwrap()
            .to_string();
        assert!(s.contains("\"screenshot\""));
        // SAFETY: from the library.
        unsafe { cmux_cu_buffer_free(b) };
    }
}
