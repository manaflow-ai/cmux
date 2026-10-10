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

#[cfg(target_os = "linux")]
use serde::{Deserialize, Serialize};
#[cfg(target_os = "linux")]
use zeroize::Zeroize;
#[cfg(target_os = "linux")]
use zeroize::Zeroizing;

#[cfg(target_os = "linux")]
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

#[cfg(target_os = "linux")]
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

#[cfg(target_os = "linux")]
impl Drop for Request {
    fn drop(&mut self) {
        if let Self::InstallOrRotate { authority: Some(authority), .. } = self {
            authority.zeroize();
        }
    }
}

#[cfg(target_os = "linux")]
#[derive(Serialize, Deserialize)]
struct Response {
    protocol: u32,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<ProviderWorkspaceAuthorityStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ResponseError>,
}

#[cfg(target_os = "linux")]
#[derive(Serialize, Deserialize)]
struct ResponseError {
    code: String,
    message: String,
}

#[cfg(target_os = "linux")]
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

#[cfg(target_os = "linux")]
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

#[cfg(target_os = "linux")]
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
    crate::platform::unix_peer_uid(stream)
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
        // Descriptor exhaustion persists across accepts; an immediate retry
        // spun this thread at 100% CPU.
        let mut backoff =
            crate::backoff::Backoff::new(Duration::from_millis(10), Duration::from_secs(1));
        for connection in listener.incoming() {
            let stream = match connection {
                Ok(stream) => {
                    backoff.reset();
                    stream
                }
                Err(error) => {
                    if crate::backoff::accept_error_needs_backoff(&error) {
                        backoff.sleep();
                    }
                    continue;
                }
            };
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
    #[cfg(target_os = "linux")]
    #[test]
    fn linux_peer_credentials_report_the_kernel_uid() {
        use std::os::unix::net::UnixStream;

        let (client, server) = UnixStream::pair().unwrap();
        assert_eq!(super::peer_uid(&server).unwrap(), unsafe { libc::geteuid() });
        drop(client);
    }
}
