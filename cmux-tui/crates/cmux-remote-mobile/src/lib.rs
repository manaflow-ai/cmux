//! A C ABI over the cmux remote client, for iOS.
//!
//! The daemon protocol is not something a phone should reimplement. Enrollment
//! is a PSK-authenticated Noise handshake, sessions are mutually authenticated
//! and resumable, frames carry per-lane sequence numbers with bounded replay,
//! and Iroh adds path selection and relay fallback underneath all of it. A
//! second implementation in Swift would be a second set of bugs in the parts
//! that are hardest to test. So the phone links the same Rust client the TUI
//! uses and this crate is only the boundary.
//!
//! The surface is deliberately small: connect, attach a shell, move bytes,
//! resize, and read a connection snapshot. Control traffic crosses as JSON
//! because it is low rate; terminal output crosses as raw bytes because it is
//! not.
//!
//! Every entry point is `unsafe` in the C sense and safe in practice only if
//! the caller respects two rules: a handle is used from one thread at a time,
//! and every returned string is released with `cmux_mobile_string_free`.

use std::collections::BTreeMap;
use std::ffi::{CStr, CString, c_char};
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cmux_remote::client::WorkspaceClient;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::identity::EnrollmentInvitation;
use cmux_remote::provider::{
    ConnectRequest, IrohPathMode, IrohProvider, IrohProviderConfig, TransportProvider,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{
    ByteString, LanePolicy, ProcessEnvironment, ProcessEvent, ProcessId, ProcessIo,
    ProcessLifetime, PtyEofPolicy, SessionId, WorkspaceRequest, WorkspaceResponse,
};
use tokio::sync::{Mutex, mpsc};
use zeroize::Zeroizing;

/// Result codes. Negative values are failures; the last message is available
/// from [`cmux_mobile_last_error`].
pub const CMUX_MOBILE_OK: i32 = 0;
pub const CMUX_MOBILE_ERROR: i32 = -1;
pub const CMUX_MOBILE_INVALID_ARGUMENT: i32 = -2;
pub const CMUX_MOBILE_TIMED_OUT: i32 = -3;
pub const CMUX_MOBILE_CLOSED: i32 = -4;

pub struct CmuxMobileClient {
    runtime: tokio::runtime::Runtime,
    connection: Arc<ClientConnection>,
    workspace: Arc<WorkspaceClient>,
    terminal: Mutex<Option<Terminal>>,
    output: Mutex<Output>,
    last_error: Mutex<Option<String>>,
    closed: AtomicBool,
}

struct Terminal {
    process: ProcessId,
    /// Monotonic per-process write identifier. The daemon deduplicates repeats,
    /// so this must never go backwards within a session.
    next_write: u64,
}

struct Output {
    receiver: mpsc::Receiver<Bytes>,
    /// Bytes from a frame that did not fit in the caller's buffer.
    pending: Bytes,
}

/// Connect to a daemon named by a `cmux://enroll/...` invitation.
///
/// The invitation is the same string the CLI accepts through `--invite-file`,
/// which is what makes a scanned QR code and a pasted line the same path. Route
/// hints inside it choose the carrier; this build dials the `iroh://` hint.
///
/// Blocks until the session is authenticated, which for a first enrollment
/// includes the owner approving the device. Returns null on failure.
///
/// # Safety
/// `invite_uri` and `device_name` must be valid NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_connect(
    invite_uri: *const c_char,
    device_name: *const c_char,
    path_mode: u32,
    error_out: *mut *mut c_char,
) -> *mut CmuxMobileClient {
    if !error_out.is_null() {
        unsafe { *error_out = ptr::null_mut() };
    }
    let Some(invite) = (unsafe { string_argument(invite_uri) }) else {
        return fail(error_out, "the invitation URI is missing or not UTF-8");
    };
    let Some(device) = (unsafe { string_argument(device_name) }) else {
        return fail(error_out, "the device name is missing or not UTF-8");
    };
    let path_mode = match path_mode {
        0 => IrohPathMode::Auto,
        1 => IrohPathMode::DirectOnly,
        2 => IrohPathMode::RelayOnly,
        other => return fail(error_out, &format!("unknown path mode {other}")),
    };

    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(error) => return fail(error_out, &format!("could not start a runtime: {error}")),
    };

    match runtime.block_on(connect(&invite, &device, path_mode)) {
        Ok((connection, workspace, output)) => Box::into_raw(Box::new(CmuxMobileClient {
            runtime,
            connection,
            workspace,
            terminal: Mutex::new(None),
            output: Mutex::new(Output { receiver: output, pending: Bytes::new() }),
            last_error: Mutex::new(None),
            closed: AtomicBool::new(false),
        })),
        Err(error) => fail(error_out, &error),
    }
}

async fn connect(
    invite: &str,
    device_name: &str,
    path_mode: IrohPathMode,
) -> Result<(Arc<ClientConnection>, Arc<WorkspaceClient>, mpsc::Receiver<Bytes>), String> {
    let invitation =
        EnrollmentInvitation::from_uri(invite).map_err(|error| format!("invalid invitation: {error}"))?;
    let daemon_public_key = invitation
        .daemon_public_key_bytes()
        .map_err(|error| format!("invalid daemon key in the invitation: {error}"))?;

    // Route hints are not authoritative: they only say where to try. The Noise
    // handshake decides whether the peer is the daemon the invitation names.
    let endpoint = invitation
        .route_hints
        .iter()
        .find(|hint| hint.starts_with("iroh://"))
        .ok_or_else(|| "the invitation carries no iroh:// route hint".to_string())?;
    let endpoint = url::Url::parse(endpoint).map_err(|error| format!("bad route hint: {error}"))?;

    let provider = IrohProvider::new(IrohProviderConfig {
        path_mode,
        ..IrohProviderConfig::default()
    })
    .map_err(|error| format!("could not configure iroh: {error}"))?;

    // A fresh session per launch: resuming another device's session id would
    // collide with its replay state.
    let mut session = [0_u8; 16];
    getrandom::fill(&mut session)
        .map_err(|error| format!("could not seed a session id: {error}"))?;
    let session = SessionId(session);
    let group = provider
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Auto,
            routing: BTreeMap::new(),
        })
        .await
        .map_err(|error| format!("could not reach the daemon: {error}"))?;

    let secret = invitation
        .secret_bytes()
        .map_err(|error| format!("invalid invitation secret: {error}"))?;
    let identity =
        StaticIdentity::generate().map_err(|error| format!("could not create a device key: {error}"))?;
    let connection = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity,
            expected_daemon: Some(daemon_public_key),
            auth: ClientAuthMode::Invitation {
                id: invitation.id.clone(),
                secret: Zeroizing::new(secret),
            },
            device_name: device_name.to_string(),
            session,
            lane_policy: LanePolicy::Auto,
            limits: SessionLimits::default(),
            // A phone changes networks often, so give reconnect a long leash
            // rather than surfacing a transient carrier loss as a failure.
            reconnect: ReconnectPolicy { maximum_attempts: None, ..ReconnectPolicy::default() },
        },
    )
    .await
    .map_err(|error| format!("the daemon refused this device: {error}"))?;

    let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
    let workspace = WorkspaceClient::connect(multiplexer)
        .await
        .map_err(|error| format!("could not open the workspace service: {error}"))?;

    let (_sender, receiver) = mpsc::channel(256);
    Ok((connection, workspace, receiver))
}

/// Open `root` on the daemon and start a login shell on a PTY of `cols` x
/// `rows`. Output becomes readable through [`cmux_mobile_read`].
///
/// # Safety
/// `root` must be a valid NUL-terminated UTF-8 path on the daemon's host.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_open_terminal(
    client: *mut CmuxMobileClient,
    root: *const c_char,
    cols: u16,
    rows: u16,
) -> i32 {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return CMUX_MOBILE_INVALID_ARGUMENT;
    };
    let Some(root) = (unsafe { string_argument(root) }) else {
        return client.record(CMUX_MOBILE_INVALID_ARGUMENT, "the workspace root is not UTF-8");
    };
    if cols == 0 || rows == 0 {
        return client.record(CMUX_MOBILE_INVALID_ARGUMENT, "the terminal size must be non-zero");
    }

    let result = client.runtime.block_on(async {
        let opened = client
            .workspace
            .request(WorkspaceRequest::OpenWorkspace { root })
            .await
            .map_err(|error| format!("open-workspace failed: {error}"))?;
        let WorkspaceResponse::Workspace { id, .. } = opened else {
            return Err(format!("open-workspace returned {opened:?}"));
        };

        // Reserve the output stream before spawning, so the first bytes a shell
        // writes cannot land before anyone is listening.
        let process = client.workspace.allocate_process_handle();
        let started = client
            .workspace
            .spawn_process_with_events(
                process,
                WorkspaceRequest::SpawnProcess {
                    workspace: id,
                    argv: vec!["/bin/sh".into(), "-lc".into(), "exec \"${SHELL:-/bin/sh}\" -l".into()],
                    cwd: None,
                    env: BTreeMap::new(),
                    io: ProcessIo::Pty {
                        cols,
                        rows,
                        term: "xterm-256color".into(),
                        eof: PtyEofPolicy::Reject,
                    },
                    lifetime: ProcessLifetime::Workspace,
                    operation: None,
                    timeout_ms: None,
                    retained_output_bytes: Some(256 * 1024),
                    environment: ProcessEnvironment::Inherit,
                },
            )
            .await
            .map_err(|error| format!("spawn-process failed: {error}"))?;

        let (sender, receiver) = mpsc::channel(256);
        let events = started.events;
        tokio::spawn(async move {
            while let Ok(Some(event)) = events.receive().await {
                let data = match event.event {
                    ProcessEvent::Stdout { data, .. } | ProcessEvent::Stderr { data, .. } => data,
                    ProcessEvent::Exit { .. } => break,
                    _ => continue,
                };
                let Ok(bytes) = data.decode() else { continue };
                if sender.send(Bytes::from(bytes)).await.is_err() {
                    break;
                }
            }
        });

        *client.terminal.lock().await = Some(Terminal { process, next_write: 1 });
        client.output.lock().await.receiver = receiver;
        Ok(())
    });

    match result {
        Ok(()) => CMUX_MOBILE_OK,
        Err(error) => client.record(CMUX_MOBILE_ERROR, &error),
    }
}

/// Copy up to `capacity` bytes of terminal output into `buffer`, waiting up to
/// `timeout_ms` for the first byte. Returns [`CMUX_MOBILE_TIMED_OUT`] when
/// nothing arrived, which is not an error.
///
/// # Safety
/// `buffer` must be writable for `capacity` bytes and `out_len` must be a valid
/// pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_read(
    client: *mut CmuxMobileClient,
    buffer: *mut u8,
    capacity: usize,
    out_len: *mut usize,
    timeout_ms: u32,
) -> i32 {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return CMUX_MOBILE_INVALID_ARGUMENT;
    };
    if buffer.is_null() || out_len.is_null() || capacity == 0 {
        return client.record(CMUX_MOBILE_INVALID_ARGUMENT, "read needs a non-empty buffer");
    }
    unsafe { *out_len = 0 };

    client.runtime.block_on(async {
        let mut output = client.output.lock().await;
        if output.pending.is_empty() {
            let waited = tokio::time::timeout(
                Duration::from_millis(u64::from(timeout_ms)),
                output.receiver.recv(),
            )
            .await;
            match waited {
                Ok(Some(bytes)) => output.pending = bytes,
                Ok(None) => return CMUX_MOBILE_CLOSED,
                Err(_) => return CMUX_MOBILE_TIMED_OUT,
            }
        }
        let take = capacity.min(output.pending.len());
        unsafe { ptr::copy_nonoverlapping(output.pending.as_ptr(), buffer, take) };
        output.pending = output.pending.slice(take..);
        unsafe { *out_len = take };
        CMUX_MOBILE_OK
    })
}

/// Send `length` bytes of keyboard input to the shell.
///
/// # Safety
/// `bytes` must be readable for `length` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_write(
    client: *mut CmuxMobileClient,
    bytes: *const u8,
    length: usize,
) -> i32 {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return CMUX_MOBILE_INVALID_ARGUMENT;
    };
    if bytes.is_null() && length != 0 {
        return client.record(CMUX_MOBILE_INVALID_ARGUMENT, "write was given a null buffer");
    }
    let data = unsafe { std::slice::from_raw_parts(bytes, length) }.to_vec();

    let result = client.runtime.block_on(async {
        let mut terminal = client.terminal.lock().await;
        let Some(terminal) = terminal.as_mut() else {
            return Err("no terminal is open".to_string());
        };
        let write_id = terminal.next_write;
        terminal.next_write += 1;
        client
            .workspace
            .request(WorkspaceRequest::WriteProcess {
                process: terminal.process,
                write_id,
                data: ByteString::from_bytes(&data),
                eof: false,
            })
            .await
            .map(|_| ())
            .map_err(|error| format!("write failed: {error}"))
    });

    match result {
        Ok(()) => CMUX_MOBILE_OK,
        Err(error) => client.record(CMUX_MOBILE_ERROR, &error),
    }
}

/// Resize the remote PTY. Call this on rotation and on keyboard show/hide.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_resize(
    client: *mut CmuxMobileClient,
    cols: u16,
    rows: u16,
) -> i32 {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return CMUX_MOBILE_INVALID_ARGUMENT;
    };
    if cols == 0 || rows == 0 {
        return client.record(CMUX_MOBILE_INVALID_ARGUMENT, "the terminal size must be non-zero");
    }

    let result = client.runtime.block_on(async {
        let terminal = client.terminal.lock().await;
        let Some(terminal) = terminal.as_ref() else {
            return Err("no terminal is open".to_string());
        };
        client
            .workspace
            .request(WorkspaceRequest::ResizeProcess { process: terminal.process, cols, rows })
            .await
            .map(|_| ())
            .map_err(|error| format!("resize failed: {error}"))
    });

    match result {
        Ok(()) => CMUX_MOBILE_OK,
        Err(error) => client.record(CMUX_MOBILE_ERROR, &error),
    }
}

/// A credential-free connection snapshot as JSON: generation, state, provider,
/// route, and whether the selected Iroh path is direct or relayed. This is what
/// a status line should show, and it is safe to log.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_snapshot_json(client: *mut CmuxMobileClient) -> *mut c_char {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return ptr::null_mut();
    };
    let snapshot = client.runtime.block_on(client.connection.snapshot());
    let json = serde_json::json!({
        "generation": snapshot.generation,
        "state": format!("{:?}", snapshot.state),
        "physical_link_count": snapshot.physical_link_count,
        "provider": snapshot.transport.provider,
        "route": snapshot.transport.route,
        "path": snapshot.transport.selected_path.map(|path| format!("{:?}", path.kind)),
    });
    into_c_string(json.to_string())
}

/// The rendered terminal as JSON: size, styled rows, cursor, default colors,
/// and the output sequence the model is current through.
///
/// The daemon keeps the terminal model, so a phone renders styled runs instead
/// of carrying a VT parser and reproducing scroll regions, wrapping, and
/// character sets on the client. Returns null when no terminal is open.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_terminal_json(client: *mut CmuxMobileClient) -> *mut c_char {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return ptr::null_mut();
    };
    let rendered = client.runtime.block_on(async {
        let terminal = client.terminal.lock().await;
        let process = terminal.as_ref()?.process;
        drop(terminal);
        let response = client
            .workspace
            .request(WorkspaceRequest::SnapshotProcessTerminal { process })
            .await
            .ok()?;
        let WorkspaceResponse::ProcessTerminalSnapshot { snapshot } = response else {
            return None;
        };
        serde_json::to_string(&snapshot).ok()
    });
    rendered.map(into_c_string).unwrap_or(ptr::null_mut())
}

/// The message behind the last failing call on this handle, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_last_error(client: *mut CmuxMobileClient) -> *mut c_char {
    let Some(client) = (unsafe { client.as_ref() }) else {
        return ptr::null_mut();
    };
    let message = client.runtime.block_on(async { client.last_error.lock().await.clone() });
    message.map(into_c_string).unwrap_or(ptr::null_mut())
}

/// Close the session and release the handle. Safe to call with null.
///
/// # Safety
/// The handle must have come from [`cmux_mobile_connect`] and must not be used
/// afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_free(client: *mut CmuxMobileClient) {
    if client.is_null() {
        return;
    }
    let client = unsafe { Box::from_raw(client) };
    if !client.closed.swap(true, Ordering::SeqCst) {
        // A graceful close tells the daemon this was intentional, so it drops
        // the resume lease instead of holding replay state for a phone that is
        // not coming back.
        let _ = client.runtime.block_on(client.connection.close());
    }
}

/// Release a string returned by this library. Safe to call with null.
///
/// # Safety
/// The pointer must have come from this library and must not be used after.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_mobile_string_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

impl CmuxMobileClient {
    fn record(&self, code: i32, message: &str) -> i32 {
        self.runtime.block_on(async {
            *self.last_error.lock().await = Some(message.to_string());
        });
        code
    }
}

unsafe fn string_argument(text: *const c_char) -> Option<String> {
    if text.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(text) }.to_str().ok().map(str::to_owned)
}

fn into_c_string(text: String) -> *mut c_char {
    CString::new(text).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

fn fail(error_out: *mut *mut c_char, message: &str) -> *mut CmuxMobileClient {
    if !error_out.is_null() {
        unsafe { *error_out = into_c_string(message.to_string()) };
    }
    ptr::null_mut()
}
