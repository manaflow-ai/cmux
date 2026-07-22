//! Root-only management protocol for live provider-owned mux processes.

#![cfg(any(target_os = "linux", test))]

use std::fmt;
#[cfg(target_os = "linux")]
use std::io::{self, Read, Write};
#[cfg(target_os = "linux")]
use std::path::Path;
#[cfg(target_os = "linux")]
use std::sync::Arc;
#[cfg(target_os = "linux")]
use std::time::Duration;

use serde::{Deserialize, Serialize};
use zeroize::Zeroize;
#[cfg(target_os = "linux")]
use zeroize::Zeroizing;

use crate::{
    Mux, ProviderWorkspaceAuthority, ProviderWorkspaceAuthorityStatus,
    ProviderWorkspaceAuthorityUpdateError,
};

pub const PROTOCOL_VERSION: u32 = 1;
#[cfg(target_os = "linux")]
const MAX_MESSAGE_BYTES: usize = 8 * 1024;
#[cfg(target_os = "linux")]
const IO_TIMEOUT: Duration = Duration::from_secs(3);

#[cfg(target_os = "linux")]
struct SensitiveBytes(Vec<u8>);

#[cfg(target_os = "linux")]
impl Drop for SensitiveBytes {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum Request {
    Status {
        protocol: u32,
    },
    InstallOrRotate {
        protocol: u32,
        mux_generation: String,
        expected_authority_generation: u64,
        authority_generation: u64,
        authority: Option<String>,
    },
}

impl Drop for Request {
    fn drop(&mut self) {
        if let Self::InstallOrRotate { authority: Some(authority), .. } = self {
            authority.zeroize();
        }
    }
}

#[derive(Serialize, Deserialize)]
struct Response {
    protocol: u32,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<ProviderWorkspaceAuthorityStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ResponseError>,
}

#[derive(Serialize, Deserialize)]
struct ResponseError {
    code: String,
    message: String,
}

impl Response {
    fn success(status: ProviderWorkspaceAuthorityStatus) -> Self {
        Self { protocol: PROTOCOL_VERSION, ok: true, status: Some(status), error: None }
    }

    fn error(code: &str, message: impl Into<String>) -> Self {
        Self {
            protocol: PROTOCOL_VERSION,
            ok: false,
            status: None,
            error: Some(ResponseError { code: code.into(), message: message.into() }),
        }
    }
}

fn update_error_code(error: ProviderWorkspaceAuthorityUpdateError) -> &'static str {
    match error {
        ProviderWorkspaceAuthorityUpdateError::Unmanaged => "unmanaged",
        ProviderWorkspaceAuthorityUpdateError::MuxGenerationMismatch => "mux_generation_mismatch",
        ProviderWorkspaceAuthorityUpdateError::ExpectedGenerationMismatch => {
            "expected_generation_mismatch"
        }
        ProviderWorkspaceAuthorityUpdateError::GenerationConflict => "generation_conflict",
        ProviderWorkspaceAuthorityUpdateError::InvalidGeneration => "invalid_generation",
    }
}

fn handle_request(mux: &Mux, peer_uid: u32, bytes: &[u8]) -> Response {
    if peer_uid != 0 {
        return Response::error("access_denied", "provider management requires root");
    }
    let mut request = match serde_json::from_slice::<Request>(bytes) {
        Ok(request) => request,
        Err(_) => return Response::error("invalid_request", "invalid management request"),
    };
    let protocol = match &request {
        Request::Status { protocol } | Request::InstallOrRotate { protocol, .. } => *protocol,
    };
    if protocol != PROTOCOL_VERSION {
        return Response::error("unsupported_version", "unsupported management protocol");
    }
    match &mut request {
        Request::Status { .. } => Response::success(mux.provider_workspace_authority_status()),
        Request::InstallOrRotate {
            mux_generation,
            expected_authority_generation,
            authority_generation,
            authority,
            ..
        } => {
            let Some(authority) = authority.take() else {
                return Response::error("invalid_request", "authority is required");
            };
            let authority = match ProviderWorkspaceAuthority::new(authority) {
                Ok(authority) => authority,
                Err(_) => {
                    return Response::error(
                        "invalid_authority",
                        "provider workspace authority is invalid",
                    );
                }
            };
            match mux.install_or_rotate_provider_workspace_authority(
                mux_generation,
                *expected_authority_generation,
                *authority_generation,
                authority,
            ) {
                Ok(status) => Response::success(status),
                Err(error) => Response::error(update_error_code(error), error.to_string()),
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn read_message(mut reader: impl Read) -> io::Result<SensitiveBytes> {
    // Read exactly one frame byte at a time. This root-only management path is
    // intentionally bounded to 8 KiB, and avoiding read-ahead means no hidden
    // library allocation can retain a credential or bytes from the next frame.
    let mut bytes = SensitiveBytes(Vec::with_capacity(MAX_MESSAGE_BYTES + 1));
    let mut byte = Zeroizing::new([0_u8; 1]);
    loop {
        match reader.read(&mut *byte) {
            Ok(0) => return Err(io::Error::from(io::ErrorKind::UnexpectedEof)),
            Ok(1) => {
                let value = byte[0];
                byte.zeroize();
                if value == b'\n' {
                    break;
                }
                bytes.0.push(value);
                if bytes.0.len() > MAX_MESSAGE_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "management request is too large",
                    ));
                }
            }
            Ok(_) => unreachable!("a one-byte read cannot return more than one byte"),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(bytes)
}

#[cfg(target_os = "linux")]
fn write_response(mut writer: impl Write, response: &Response) -> io::Result<()> {
    serde_json::to_writer(&mut writer, response)?;
    writer.write_all(b"\n")?;
    writer.flush()
}

#[cfg(target_os = "linux")]
fn peer_uid(stream: &std::os::unix::net::UnixStream) -> io::Result<u32> {
    use std::mem::{size_of, zeroed};
    use std::os::fd::AsRawFd;

    let mut credentials = unsafe { zeroed::<libc::ucred>() };
    let mut length = size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut credentials).cast(),
            &raw mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != size_of::<libc::ucred>() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid peer credentials"));
    }
    Ok(credentials.uid)
}

/// Serves the systemd-provided listener in a detached thread. Each peer is
/// credential-checked before any request bytes are read.
#[cfg(target_os = "linux")]
pub fn serve(
    listener: std::os::unix::net::UnixListener,
    mux: Arc<Mux>,
) -> io::Result<std::thread::JoinHandle<()>> {
    let result = unsafe { libc::prctl(libc::PR_SET_DUMPABLE, 0, 0, 0, 0) };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    std::thread::Builder::new().name("provider-management".into()).spawn(move || {
        for connection in listener.incoming() {
            let Ok(stream) = connection else { continue };
            let mux = mux.clone();
            let _ = std::thread::Builder::new().name("provider-management-peer".into()).spawn(
                move || {
                    let Ok(uid) = peer_uid(&stream) else { return };
                    if uid != 0 {
                        let _ = write_response(
                            &stream,
                            &Response::error("access_denied", "provider management requires root"),
                        );
                        return;
                    }
                    let _ = stream.set_read_timeout(Some(IO_TIMEOUT));
                    let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
                    let Ok(bytes) = read_message(&stream) else { return };
                    let response = handle_request(&mux, uid, &bytes.0);
                    let _ = write_response(&stream, &response);
                },
            );
        }
    })
}

#[derive(Debug)]
pub enum ClientError {
    UpgradeRequired,
    Unavailable,
    Rejected { code: String, message: String },
    InvalidResponse,
}

impl fmt::Display for ClientError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UpgradeRequired => formatter.write_str(
                "running cmux-tui does not support live provider authority management; upgrade required",
            ),
            Self::Unavailable => {
                formatter.write_str("live provider authority management is unavailable")
            }
            Self::Rejected { code, message } => write!(formatter, "{code}: {message}"),
            Self::InvalidResponse => formatter.write_str("invalid provider management response"),
        }
    }
}

impl std::error::Error for ClientError {}

#[cfg(target_os = "linux")]
fn exchange(socket: &Path, request: &impl Serialize) -> Result<Response, ClientError> {
    use std::os::unix::net::UnixStream;

    let mut stream = UnixStream::connect(socket).map_err(|_| ClientError::Unavailable)?;
    stream.set_read_timeout(Some(IO_TIMEOUT)).map_err(|_| ClientError::Unavailable)?;
    stream.set_write_timeout(Some(IO_TIMEOUT)).map_err(|_| ClientError::Unavailable)?;
    let mut encoded =
        SensitiveBytes(serde_json::to_vec(request).map_err(|_| ClientError::InvalidResponse)?);
    encoded.0.push(b'\n');
    stream.write_all(&encoded.0).map_err(|_| ClientError::Unavailable)?;
    stream.flush().map_err(|_| ClientError::Unavailable)?;
    let response = read_message(&stream).map_err(|_| ClientError::Unavailable)?;
    serde_json::from_slice(&response.0).map_err(|_| ClientError::InvalidResponse)
}

#[cfg(target_os = "linux")]
#[derive(Serialize)]
struct StatusRequest {
    protocol: u32,
    operation: &'static str,
}

#[cfg(target_os = "linux")]
#[derive(Serialize)]
struct InstallRequest<'a> {
    protocol: u32,
    operation: &'static str,
    mux_generation: &'a str,
    expected_authority_generation: u64,
    authority_generation: u64,
    authority: &'a str,
}

/// Installs or rotates a credential without exposing it in process arguments.
#[cfg(target_os = "linux")]
pub fn install(
    socket: &Path,
    authority_generation: u64,
    authority: ProviderWorkspaceAuthority,
) -> Result<ProviderWorkspaceAuthorityStatus, ClientError> {
    let status_response =
        exchange(socket, &StatusRequest { protocol: PROTOCOL_VERSION, operation: "status" })?;
    let status = response_status(status_response)?;
    let mux_generation = status.mux_generation.as_deref().ok_or_else(|| ClientError::Rejected {
        code: "unmanaged".into(),
        message: "running mux is not managed through the provider socket".into(),
    })?;
    let response = exchange(
        socket,
        &InstallRequest {
            protocol: PROTOCOL_VERSION,
            operation: "install_or_rotate",
            mux_generation,
            expected_authority_generation: status.authority_generation,
            authority_generation,
            authority: std::str::from_utf8(authority.expose())
                .expect("validated provider authority is UTF-8"),
        },
    )?;
    response_status(response)
}

#[cfg(target_os = "linux")]
fn response_status(response: Response) -> Result<ProviderWorkspaceAuthorityStatus, ClientError> {
    if !response.ok
        && response.error.as_ref().is_some_and(|error| error.code == "unsupported_version")
    {
        return Err(ClientError::UpgradeRequired);
    }
    if response.protocol != PROTOCOL_VERSION {
        return Err(ClientError::InvalidResponse);
    }
    if response.ok {
        return response.status.ok_or(ClientError::InvalidResponse);
    }
    let error = response.error.ok_or(ClientError::InvalidResponse)?;
    Err(ClientError::Rejected { code: error.code, message: error.message })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SurfaceOptions;
    use std::sync::Arc;

    const MUX_GENERATION: &str = "0123456789abcdef0123456789abcdef";
    const AUTHORITY_ONE: &str = "provider-authority-one-0000000000000001";
    const AUTHORITY_TWO: &str = "provider-authority-two-0000000000000002";

    fn mux() -> Arc<Mux> {
        Mux::new_provider_managed_pending_for_test(
            "management-test",
            SurfaceOptions::default(),
            MUX_GENERATION,
        )
    }

    fn request(value: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&value).unwrap()
    }

    #[test]
    fn non_root_is_rejected_before_parsing() {
        let response = handle_request(&mux(), 501, b"this is deliberately not JSON");
        assert!(!response.ok);
        assert_eq!(response.error.unwrap().code, "access_denied");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn explicit_unsupported_response_is_the_only_upgrade_signal() {
        let mut unsupported = Response::error("unsupported_version", "future protocol");
        unsupported.protocol = PROTOCOL_VERSION + 1;
        assert!(matches!(response_status(unsupported), Err(ClientError::UpgradeRequired)));
        let rejected = Response::error("unmanaged", "not configured");
        assert!(matches!(response_status(rejected), Err(ClientError::Rejected { .. })));
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn management_read_never_copies_trailing_secret_or_reallocates() {
        let line = format!(
            "{{\"protocol\":1,\"operation\":\"install_or_rotate\",\"authority\":\"{AUTHORITY_ONE}\"}}\n"
        );
        let encoded = format!("{line}trailing-secret-that-must-remain-unread");
        let mut reader = io::Cursor::new(encoded.as_bytes());

        let message = read_message(&mut reader).unwrap();

        assert_eq!(reader.position(), line.len() as u64, "reader copied bytes after the frame");
        assert!(
            message.0.capacity() > MAX_MESSAGE_BYTES,
            "sensitive message storage could reallocate without scrubbing the old allocation"
        );
        assert_eq!(message.0, line.as_bytes()[..line.len() - 1]);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn management_read_rejects_eof_before_the_frame_delimiter() {
        let Err(error) = read_message(io::Cursor::new(br#"{"protocol":1,"operation":"status"}"#))
        else {
            panic!("EOF without a frame delimiter was accepted");
        };
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn initial_install_accepts_a_durable_generation_after_mux_restart() {
        let mux = mux();
        let response = handle_request(
            &mux,
            0,
            &request(serde_json::json!({
                "protocol": 1,
                "operation": "install_or_rotate",
                "mux_generation": MUX_GENERATION,
                "expected_authority_generation": 0,
                "authority_generation": 19,
                "authority": AUTHORITY_ONE,
            })),
        );
        assert!(response.ok);
        let status = response.status.unwrap();
        assert_eq!(status.authority_generation, 19);
        assert!(status.authority_installed);
        mux.authorize_provider_workspace_authority(AUTHORITY_ONE).unwrap();
    }

    #[test]
    fn same_generation_is_idempotent_only_for_the_same_secret() {
        let mux = mux();
        let install = |authority: &str, expected| {
            handle_request(
                &mux,
                0,
                &request(serde_json::json!({
                    "protocol": 1,
                    "operation": "install_or_rotate",
                    "mux_generation": MUX_GENERATION,
                    "expected_authority_generation": expected,
                    "authority_generation": 3,
                    "authority": authority,
                })),
            )
        };
        assert!(install(AUTHORITY_ONE, 0).ok);
        assert!(install(AUTHORITY_ONE, 99).ok);
        let conflict = install(AUTHORITY_TWO, 3);
        assert_eq!(conflict.error.unwrap().code, "generation_conflict");
    }

    #[test]
    fn rotation_is_exact_compare_and_swap() {
        let mux = mux();
        mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            0,
            7,
            ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
        )
        .unwrap();
        let stale = mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            6,
            8,
            ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
        );
        assert_eq!(
            stale.unwrap_err(),
            ProviderWorkspaceAuthorityUpdateError::ExpectedGenerationMismatch
        );
        let gap = mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            7,
            9,
            ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
        );
        assert_eq!(gap.unwrap_err(), ProviderWorkspaceAuthorityUpdateError::InvalidGeneration);
        mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            7,
            8,
            ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
        )
        .unwrap();
        assert!(mux.authorize_provider_workspace_authority(AUTHORITY_ONE).is_err());
        mux.authorize_provider_workspace_authority(AUTHORITY_TWO).unwrap();
    }

    #[test]
    fn stale_mux_generation_and_downgrade_are_rejected() {
        let mux = mux();
        let wrong_mux = mux.install_or_rotate_provider_workspace_authority(
            "ffffffffffffffffffffffffffffffff",
            0,
            1,
            ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
        );
        assert_eq!(
            wrong_mux.unwrap_err(),
            ProviderWorkspaceAuthorityUpdateError::MuxGenerationMismatch
        );
        mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            0,
            4,
            ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
        )
        .unwrap();
        let downgrade = mux.install_or_rotate_provider_workspace_authority(
            MUX_GENERATION,
            4,
            3,
            ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
        );
        assert_eq!(
            downgrade.unwrap_err(),
            ProviderWorkspaceAuthorityUpdateError::InvalidGeneration
        );
    }

    #[test]
    fn concurrent_identical_install_is_idempotent() {
        let mux = mux();
        let mut installers = Vec::new();
        for _ in 0..8 {
            let mux = mux.clone();
            installers.push(std::thread::spawn(move || {
                mux.install_or_rotate_provider_workspace_authority(
                    MUX_GENERATION,
                    0,
                    11,
                    ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
                )
            }));
        }
        for installer in installers {
            assert_eq!(installer.join().unwrap().unwrap().authority_generation, 11);
        }
    }

    #[test]
    fn pending_mux_blocks_direct_lifecycle_mutation_before_install() {
        let mux = mux();
        let workspace = mux
            .create_empty_workspace(Some("managed".into()), Some("managed-key".into()), None)
            .unwrap();
        let error = mux
            .rename_workspace_at_revision(workspace.workspace, "escaped".into(), None)
            .unwrap_err();
        assert!(error.to_string().contains("provider-managed workspace directly"));
        assert_eq!(mux.with_state(|state| state.workspaces[0].name.clone()), "managed");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_peer_credentials_report_the_kernel_uid() {
        use std::os::unix::net::UnixStream;

        let (client, server) = UnixStream::pair().unwrap();
        assert_eq!(peer_uid(&server).unwrap(), unsafe { libc::geteuid() });
        drop(client);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn root_client_round_trips_over_the_bounded_socket_protocol() {
        use std::os::unix::net::UnixListener;

        if unsafe { libc::geteuid() } != 0 {
            return;
        }
        let socket = std::env::temp_dir()
            .join(format!("cmux-provider-management-test-{}.sock", std::process::id()));
        let listener = UnixListener::bind(&socket).unwrap();
        let mux = mux();
        let server_mux = mux.clone();
        let server = std::thread::spawn(move || {
            for _ in 0..2 {
                let (stream, _) = listener.accept().unwrap();
                let uid = peer_uid(&stream).unwrap();
                let bytes = read_message(&stream).unwrap();
                let response = handle_request(&server_mux, uid, &bytes.0);
                write_response(&stream, &response).unwrap();
            }
        });

        let status =
            install(&socket, 23, ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap()).unwrap();
        server.join().unwrap();
        std::fs::remove_file(socket).unwrap();
        assert_eq!(status.authority_generation, 23);
        mux.authorize_provider_workspace_authority(AUTHORITY_ONE).unwrap();
    }

    #[test]
    fn management_responses_never_contain_authority() {
        let mux = mux();
        let response = handle_request(
            &mux,
            0,
            &request(serde_json::json!({
                "protocol": 1,
                "operation": "install_or_rotate",
                "mux_generation": MUX_GENERATION,
                "expected_authority_generation": 0,
                "authority_generation": 1,
                "authority": AUTHORITY_ONE,
            })),
        );
        let encoded = serde_json::to_string(&response).unwrap();
        assert!(!encoded.contains(AUTHORITY_ONE));
        assert!(!encoded.contains("authority-one"));
    }
}
