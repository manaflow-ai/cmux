//! Local CodeRouter handoff input.
//!
//! New cmux builds launch CodeRouter with a hidden argv form and a local,
//! authenticated Unix socket. The socket returns a short-lived one-use lease;
//! it never returns Stack credentials. The old inherited-FD and environment
//! marker transports are deliberately not accepted by this release.

use std::env;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
#[cfg(unix)]
use std::time::Instant;

#[cfg(unix)]
use base64::Engine;
#[cfg(unix)]
use serde::Deserialize;
#[cfg(unix)]
use serde_json::json;
use sha2::{Digest, Sha256};
use time::{OffsetDateTime, format_description::well_known::Rfc3339};
use zeroize::Zeroizing;

use crate::cli::Error;

pub const HIDDEN_HANDOFF_COMMAND: &str = "__cmux-handoff-v2";
const HANDOFF_FAILURE_MESSAGE: &str = "coderouter handoff is invalid or no longer available";
#[cfg(unix)]
pub const SOCKET_PROTOCOL_VERSION: u8 = 2;

#[cfg(unix)]
// Every callback request and response is one LF-terminated raw frame.  Keep
// the cap small enough that a peer cannot turn the handoff socket into an
// unbounded memory or buffering channel.  The limit includes the LF byte.
const MAX_SOCKET_FRAME_BYTES: usize = 4 * 1024;
#[cfg(unix)]
const HANDOFF_CHALLENGE_BYTES: usize = 32;
#[cfg(unix)]
const HANDOFF_CHALLENGE_TEXT_BYTES: usize = 43;
// macOS sockaddr_un reserves 104 bytes for a pathname, including the NUL.
const MAX_SOCKET_PATH_BYTES: usize = 103;
#[cfg(unix)]
const SOCKET_TOTAL_TIMEOUT_SECS: u64 = 25;
#[cfg(unix)]
const LEASE_PREFIX: &str = "crh_";
#[cfg(unix)]
const LEASE_SUFFIX_LENGTH: usize = 43;

#[derive(Debug)]
struct SocketRequestOverride {
    path: PathBuf,
    team_binding: String,
}

static SOCKET_PATH_OVERRIDE: OnceLock<Mutex<Option<SocketRequestOverride>>> = OnceLock::new();
static EXPECTED_TEAM_BINDING: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn socket_path_override() -> &'static Mutex<Option<SocketRequestOverride>> {
    SOCKET_PATH_OVERRIDE.get_or_init(|| Mutex::new(None))
}

fn expected_team_binding() -> &'static Mutex<Option<String>> {
    EXPECTED_TEAM_BINDING.get_or_init(|| Mutex::new(None))
}

pub fn clear_hidden_state() {
    *socket_path_override()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    *expected_team_binding()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
}

pub struct HiddenStateReset;

impl HiddenStateReset {
    pub fn new() -> Self {
        clear_hidden_state();
        Self
    }
}

impl Drop for HiddenStateReset {
    fn drop(&mut self) {
        clear_hidden_state();
    }
}

/// Return whether the hidden socket handoff form was requested.
pub fn requested() -> bool {
    socket_path_override()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .is_some()
        || expected_team_binding()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .is_some()
}

/// Return whether the process contains a retired handoff activation marker.
pub fn obsolete_marker_present() -> bool {
    env::var_os("CODEROUTER_HANDOFF_FD").is_some()
        || env::var_os("CODEROUTER_CMUX_HANDOFF_SOCKET").is_some()
}

/// Validate and remove the hidden cmux argv prefix.
pub fn rewrite_hidden_args(
    args: &[std::ffi::OsString],
) -> Result<Option<Vec<std::ffi::OsString>>, Error> {
    let Some((request, rewritten)) = parse_hidden_args(args)? else {
        return Ok(None);
    };
    let team_binding = request.team_binding.clone();
    clear_hidden_state();
    *socket_path_override()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(request);
    *expected_team_binding()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(team_binding);
    Ok(Some(rewritten))
}

fn parse_hidden_args(
    args: &[std::ffi::OsString],
) -> Result<Option<(SocketRequestOverride, Vec<std::ffi::OsString>)>, Error> {
    if args.first().and_then(|value| value.to_str()) != Some(HIDDEN_HANDOFF_COMMAND) {
        return Ok(None);
    }
    if args.len() < 5 {
        return Err(Error::Usage("coderouter handoff command is invalid".into()));
    }
    let path = args[1]
        .to_str()
        .ok_or_else(|| Error::Usage("coderouter handoff command is invalid".into()))?;
    validate_socket_path(Path::new(path))?;
    let team_binding = args[2]
        .to_str()
        .ok_or_else(|| Error::Usage("coderouter handoff command is invalid".into()))?;
    if !is_valid_team_binding(team_binding) || args[3].to_str() != Some("--") {
        return Err(Error::Usage("coderouter handoff command is invalid".into()));
    }
    let command = args[4]
        .to_str()
        .ok_or_else(|| Error::Usage("coderouter handoff command is invalid".into()))?;
    if !matches!(command, "codex" | "opencode" | "pi") {
        return Err(Error::Usage("coderouter handoff command is invalid".into()));
    }

    Ok(Some((
        SocketRequestOverride {
            path: PathBuf::from(path),
            team_binding: team_binding.to_owned(),
        },
        args[4..].to_vec(),
    )))
}

pub fn validate_socket_path(path: &Path) -> Result<(), Error> {
    let value = path
        .to_str()
        .ok_or_else(|| Error::Usage("coderouter handoff socket path is invalid".into()))?;
    if value.is_empty()
        || value.len() > MAX_SOCKET_PATH_BYTES
        || !path.is_absolute()
        || value.chars().any(is_protocol_control)
    {
        return Err(Error::Usage(
            "coderouter handoff socket path is invalid".into(),
        ));
    }
    Ok(())
}

/// Consume the one-use socket lease, if the hidden form requested it.
pub fn take_lease() -> Result<Option<Zeroizing<String>>, Error> {
    let request = socket_path_override()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();
    let Some(request) = request else {
        return Ok(None);
    };
    #[cfg(unix)]
    {
        read_socket(&request.path, Some(&request.team_binding))
            .map(Some)
            // The peer is local but not trusted. Do not expose its text or
            // distinguish parsing, framing, connection, and timeout failures.
            .map_err(|_| Error::Backend(HANDOFF_FAILURE_MESSAGE.into()))
    }
    #[cfg(not(unix))]
    {
        let SocketRequestOverride { path, team_binding } = request;
        let _ = (path, team_binding);
        Err(Error::Backend(HANDOFF_FAILURE_MESSAGE.into()))
    }
}

#[cfg(unix)]
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SocketBeginSuccess {
    id: String,
    ok: bool,
    result: SocketBeginResult,
}

#[cfg(unix)]
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SocketBeginResult {
    #[serde(rename = "protocolVersion")]
    protocol_version: u8,
    challenge: Zeroizing<String>,
}

#[cfg(unix)]
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SocketCompleteSuccess {
    id: String,
    ok: bool,
    result: SocketGrant,
}

#[cfg(unix)]
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct SocketGrant {
    #[serde(rename = "teamId")]
    team_id: String,
    lease: Zeroizing<String>,
    #[serde(rename = "expiresAt")]
    expires_at: String,
}

#[cfg(unix)]
fn read_socket(
    path: &Path,
    expected_team_binding: Option<&str>,
) -> Result<Zeroizing<String>, Error> {
    use std::os::fd::AsRawFd;
    use std::time::Duration;

    validate_socket_path(path)
        .map_err(|_| Error::Backend("coderouter handoff socket path is invalid".into()))?;
    let deadline = Instant::now() + Duration::from_secs(SOCKET_TOTAL_TIMEOUT_SECS);
    let mut stream = connect_socket(path, deadline)?;
    mark_close_on_exec(stream.as_raw_fd())?;

    let begin_request = serde_json::to_vec(&json!({
        "id": "coderouter-handoff-begin",
        "method": "coderouter.handoff.begin",
        "params": { "protocolVersion": SOCKET_PROTOCOL_VERSION },
    }))
    .map_err(|_| Error::Backend("could not encode coderouter handoff request".into()))?;
    write_framed_request(&mut stream, begin_request, deadline)?;

    // The server challenge is a post-exec liveness proof.  Do not send the
    // completion frame until this response has been parsed and validated.
    let begin_response = read_socket_frame(&mut stream, deadline)?;
    let challenge = parse_socket_challenge(&begin_response)?;
    let complete_request = serde_json::to_vec(&json!({
        "id": "coderouter-handoff-complete",
        "method": "coderouter.handoff.complete",
        "params": {
            "protocolVersion": SOCKET_PROTOCOL_VERSION,
            "challenge": challenge.as_str(),
        },
    }))
    .map_err(|_| Error::Backend("could not encode coderouter handoff request".into()))?;
    write_framed_request(&mut stream, complete_request, deadline)?;

    // The server closes after the final lease response.  Requiring EOF here
    // prevents a valid response followed by delayed bytes from being
    // accepted as a complete handoff.
    let response = read_final_socket_frame(&mut stream, deadline)?;
    parse_socket_grant(&response, expected_team_binding)
}

#[cfg(unix)]
fn write_framed_request(
    stream: &mut std::os::unix::net::UnixStream,
    request: Vec<u8>,
    deadline: Instant,
) -> Result<(), Error> {
    if request.len().saturating_add(1) > MAX_SOCKET_FRAME_BYTES {
        return Err(Error::Backend(
            "coderouter handoff request is too large".into(),
        ));
    }
    let mut framed_request = Zeroizing::new(request);
    framed_request.push(b'\n');
    write_socket_frame(stream, &framed_request, deadline)
}

#[cfg(unix)]
fn connect_socket(path: &Path, deadline: Instant) -> Result<std::os::unix::net::UnixStream, Error> {
    use std::os::fd::{FromRawFd, IntoRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::net::UnixStream;

    // SAFETY: socket returns a new descriptor or a negative errno result.
    let raw_fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if raw_fd < 0 {
        return Err(Error::Backend(
            "could not connect to coderouter handoff socket".into(),
        ));
    }
    // SAFETY: raw_fd is newly owned by this function.
    let owned_fd = unsafe { OwnedFd::from_raw_fd(raw_fd) };
    mark_close_on_exec(raw_fd)?;
    #[cfg(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "tvos",
        target_os = "watchos",
        target_os = "visionos"
    ))]
    {
        let no_sigpipe: libc::c_int = 1;
        // SAFETY: no_sigpipe is a valid integer socket-option input.
        if unsafe {
            libc::setsockopt(
                raw_fd,
                libc::SOL_SOCKET,
                libc::SO_NOSIGPIPE,
                &no_sigpipe as *const libc::c_int as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        } < 0
        {
            return Err(Error::Backend(
                "could not secure coderouter handoff socket".into(),
            ));
        }
    }
    // SAFETY: zero is a valid initial state for sockaddr_un.
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    let path_bytes = path.as_os_str().as_bytes();
    for (destination, source) in address.sun_path.iter_mut().zip(path_bytes.iter()) {
        *destination = *source as libc::c_char;
    }
    let address_start = &address as *const libc::sockaddr_un as usize;
    let path_start = address.sun_path.as_ptr() as usize;
    let address_length = (path_start - address_start) + path_bytes.len() + 1;
    #[cfg(any(
        target_os = "macos",
        target_os = "ios",
        target_os = "tvos",
        target_os = "watchos",
        target_os = "visionos"
    ))]
    {
        address.sun_len = address_length as u8;
    }

    // Keep connect inside the same absolute deadline as write and read.
    let flags = unsafe { libc::fcntl(raw_fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(raw_fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(Error::Backend(
            "could not connect to coderouter handoff socket".into(),
        ));
    }
    // SAFETY: address is initialized, and address_length covers its pathname.
    let result = unsafe {
        libc::connect(
            raw_fd,
            &address as *const libc::sockaddr_un as *const libc::sockaddr,
            address_length as libc::socklen_t,
        )
    };
    if result < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EINPROGRESS) {
        return Err(Error::Backend(
            "could not connect to coderouter handoff socket".into(),
        ));
    }
    if result < 0 {
        wait_for_socket_connect(raw_fd, deadline)?;
    }
    if unsafe { libc::fcntl(raw_fd, libc::F_SETFL, flags & !libc::O_NONBLOCK) } < 0 {
        return Err(Error::Backend(
            "could not connect to coderouter handoff socket".into(),
        ));
    }
    Ok(unsafe { UnixStream::from_raw_fd(owned_fd.into_raw_fd()) })
}

#[cfg(unix)]
fn wait_for_socket_connect(fd: std::os::fd::RawFd, deadline: Instant) -> Result<(), Error> {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Error::Backend("coderouter handoff socket timed out".into()));
        }
        let timeout_ms = remaining.as_millis().min(i32::MAX as u128).max(1) as i32;
        let mut descriptor = libc::pollfd {
            fd,
            events: libc::POLLOUT,
            revents: 0,
        };
        // SAFETY: descriptor points to one initialized pollfd.
        let ready = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
        if ready < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if ready <= 0 {
            return Err(Error::Backend("coderouter handoff socket timed out".into()));
        }
        let mut socket_error: libc::c_int = 0;
        let mut length = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        // SAFETY: socket_error and length are valid getsockopt output buffers.
        let result = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                &mut socket_error as *mut libc::c_int as *mut libc::c_void,
                &mut length,
            )
        };
        if result == 0 && socket_error == 0 {
            return Ok(());
        }
        return Err(Error::Backend(
            "could not connect to coderouter handoff socket".into(),
        ));
    }
}

#[cfg(unix)]
fn mark_close_on_exec(fd: std::os::fd::RawFd) -> Result<(), Error> {
    // SAFETY: fcntl operates on the live descriptor owned by UnixStream.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0 {
        return Err(Error::Backend(
            "could not secure coderouter handoff socket".into(),
        ));
    }
    Ok(())
}

#[cfg(unix)]
fn write_socket_frame(
    stream: &mut std::os::unix::net::UnixStream,
    frame: &[u8],
    deadline: Instant,
) -> Result<(), Error> {
    use std::io::Write;
    let mut offset = 0;
    while offset < frame.len() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Error::Backend("coderouter handoff socket timed out".into()));
        }
        stream
            .set_write_timeout(Some(remaining))
            .map_err(|_| Error::Backend("could not write coderouter handoff request".into()))?;
        match stream.write(&frame[offset..]) {
            Ok(0) => {
                return Err(Error::Backend(
                    "could not write coderouter handoff request".into(),
                ));
            }
            Ok(count) => offset += count,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
            Err(_) => {
                return Err(Error::Backend(
                    "could not write coderouter handoff request".into(),
                ));
            }
        }
    }
    Ok(())
}

#[cfg(unix)]
fn read_socket_frame(
    stream: &mut std::os::unix::net::UnixStream,
    deadline: Instant,
) -> Result<Zeroizing<Vec<u8>>, Error> {
    read_socket_frame_inner(stream, deadline, false)
}

#[cfg(unix)]
fn read_final_socket_frame(
    stream: &mut std::os::unix::net::UnixStream,
    deadline: Instant,
) -> Result<Zeroizing<Vec<u8>>, Error> {
    read_socket_frame_inner(stream, deadline, true)
}

#[cfg(unix)]
fn read_socket_frame_inner(
    stream: &mut std::os::unix::net::UnixStream,
    deadline: Instant,
    require_eof: bool,
) -> Result<Zeroizing<Vec<u8>>, Error> {
    use std::io::Read;
    let mut bytes = Zeroizing::new(Vec::with_capacity(1024));
    let mut chunk = Zeroizing::new([0_u8; 4096]);
    let mut frame_complete = false;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(Error::Backend("coderouter handoff socket timed out".into()));
        }
        stream
            .set_read_timeout(Some(remaining))
            .map_err(|_| Error::Backend("could not read coderouter handoff response".into()))?;
        match stream.read(&mut chunk[..]) {
            Ok(0) => {
                if frame_complete {
                    return Ok(bytes);
                }
                return Err(Error::Backend(
                    "coderouter handoff socket closed before its response".into(),
                ));
            }
            Ok(count) => {
                if frame_complete {
                    return Err(Error::Backend(
                        "coderouter handoff response has extra frame data".into(),
                    ));
                }
                if bytes.len().saturating_add(count) > MAX_SOCKET_FRAME_BYTES {
                    return Err(Error::Backend(
                        "coderouter handoff response is too large".into(),
                    ));
                }
                bytes.extend_from_slice(&chunk[..count]);
                if let Some(newline) = bytes.iter().position(|byte| *byte == b'\n') {
                    if newline + 1 != bytes.len() {
                        return Err(Error::Backend(
                            "coderouter handoff response has extra frame data".into(),
                        ));
                    }
                    bytes.truncate(newline);
                    if !require_eof {
                        return Ok(bytes);
                    }
                    frame_complete = true;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => continue,
            Err(_) => {
                return Err(Error::Backend(
                    "could not read coderouter handoff response".into(),
                ));
            }
        }
    }
}

#[cfg(unix)]
fn parse_socket_grant(
    bytes: &[u8],
    expected_team_binding: Option<&str>,
) -> Result<Zeroizing<String>, Error> {
    if !has_exact_json_frame(bytes) {
        return Err(Error::Backend(
            "coderouter handoff response is invalid".into(),
        ));
    }
    let response: SocketCompleteSuccess = serde_json::from_slice(bytes)
        .map_err(|_| Error::Backend("coderouter handoff response is invalid".into()))?;
    let SocketCompleteSuccess { id, ok, result } = response;
    let SocketGrant {
        team_id,
        lease,
        expires_at,
    } = result;
    if id != "coderouter-handoff-complete" || !ok {
        return Err(Error::Backend(
            "coderouter handoff response is invalid".into(),
        ));
    }
    if !is_valid_team_id(&team_id)
        || !is_valid_lease(&lease)
        || !is_valid_expiry(&expires_at)
        || expected_team_binding.is_some_and(|binding| team_binding(&team_id) != binding)
    {
        return Err(Error::Backend(
            "coderouter handoff response is invalid".into(),
        ));
    }
    Ok(lease)
}

#[cfg(unix)]
fn parse_socket_challenge(bytes: &[u8]) -> Result<Zeroizing<String>, Error> {
    if !has_exact_json_frame(bytes) {
        return Err(Error::Backend(
            "coderouter handoff response is invalid".into(),
        ));
    }
    let response: SocketBeginSuccess = serde_json::from_slice(bytes)
        .map_err(|_| Error::Backend("coderouter handoff response is invalid".into()))?;
    let SocketBeginSuccess { id, ok, result } = response;
    if id != "coderouter-handoff-begin" || !ok || result.protocol_version != SOCKET_PROTOCOL_VERSION
    {
        return Err(Error::Backend(
            "coderouter handoff response is invalid".into(),
        ));
    }
    let challenge = result.challenge;
    if !is_canonical_challenge(&challenge) {
        return Err(Error::Backend(
            "coderouter handoff response is invalid".into(),
        ));
    }
    Ok(challenge)
}

#[cfg(unix)]
fn has_exact_json_frame(bytes: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    !text.is_empty() && text == text.trim()
}

#[cfg(unix)]
fn is_canonical_challenge(value: &str) -> bool {
    if value.len() != HANDOFF_CHALLENGE_TEXT_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
    {
        return false;
    }
    let engine = base64::engine::general_purpose::URL_SAFE_NO_PAD;
    let Ok(decoded) = engine.decode(value.as_bytes()) else {
        return false;
    };
    decoded.len() == HANDOFF_CHALLENGE_BYTES && engine.encode(decoded) == value
}

#[cfg(unix)]
fn is_valid_team_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 200
        && value
            .chars()
            .all(|character| !is_protocol_control(character) && !character.is_whitespace())
}

/// Match the Unicode Cc and Cf scalar classes used by native cmux validation.
pub fn is_protocol_control(character: char) -> bool {
    if character.is_control() {
        return true;
    }
    matches!(
        character as u32,
        0x00AD
            | 0x0600..=0x0605
            | 0x061C
            | 0x06DD
            | 0x070F
            | 0x0890..=0x0891
            | 0x08E2
            | 0x180E
            | 0x200B..=0x200F
            | 0x202A..=0x202E
            | 0x2060..=0x2064
            | 0x2066..=0x206F
            | 0xFEFF
            | 0xFFF9..=0xFFFB
            | 0x110BD
            | 0x110CD
            | 0x13430..=0x1343F
            | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A
            | 0xE0001
            | 0xE0020..=0xE007F
    )
}

pub fn is_valid_team_binding(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

pub fn team_binding(team_id: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"cmux-coderouter-team-v1\0");
    digest.update(team_id.as_bytes());
    digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub fn validate_exchanged_team_id(team_id: &str) -> Result<(), Error> {
    let binding = expected_team_binding()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();
    if binding.is_some_and(|binding| team_binding(team_id) != binding) {
        return Err(Error::Backend(
            "coderouter handoff response has an invalid team binding".into(),
        ));
    }
    Ok(())
}

pub(crate) fn is_valid_expiry(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() < 20 || bytes.len() > 128 {
        return false;
    }
    let fixed_digits = [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18];
    if fixed_digits
        .iter()
        .any(|index| !bytes[*index].is_ascii_digit())
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || &bytes[..4] == b"0000"
    {
        return false;
    }
    let seconds = (bytes[17] - b'0') * 10 + (bytes[18] - b'0');
    if seconds > 59 {
        return false;
    }
    let mut timezone_index = 19;
    if bytes.get(timezone_index) == Some(&b'.') {
        timezone_index += 1;
        let fraction_start = timezone_index;
        while bytes.get(timezone_index).is_some_and(u8::is_ascii_digit) {
            timezone_index += 1;
        }
        let fraction_length = timezone_index - fraction_start;
        if fraction_length == 0 || fraction_length > 9 {
            return false;
        }
    }
    let timezone_is_canonical = if bytes.get(timezone_index) == Some(&b'Z') {
        timezone_index + 1 == bytes.len()
    } else {
        timezone_index + 6 == bytes.len()
            && matches!(bytes[timezone_index], b'+' | b'-')
            && bytes[timezone_index + 1].is_ascii_digit()
            && bytes[timezone_index + 2].is_ascii_digit()
            && bytes[timezone_index + 3] == b':'
            && bytes[timezone_index + 4].is_ascii_digit()
            && bytes[timezone_index + 5].is_ascii_digit()
    };
    if !timezone_is_canonical {
        return false;
    }
    OffsetDateTime::parse(value, &Rfc3339)
        .map(|expiry| expiry > OffsetDateTime::now_utc())
        .unwrap_or(false)
}

#[cfg(unix)]
pub fn is_valid_lease(value: &str) -> bool {
    let Some(suffix) = value.strip_prefix(LEASE_PREFIX) else {
        return false;
    };
    suffix.len() == LEASE_SUFFIX_LENGTH
        && suffix
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn team_binding_is_lowercase_and_exact() {
        let binding = team_binding("team-handoff");
        assert_eq!(binding.len(), 64);
        assert!(is_valid_team_binding(&binding));
        assert!(!is_valid_team_binding(&binding.to_uppercase()));
    }

    #[cfg(unix)]
    #[test]
    fn challenge_requires_canonical_unpadded_base64url_for_32_bytes() {
        let valid = "A".repeat(HANDOFF_CHALLENGE_TEXT_BYTES);
        assert!(is_canonical_challenge(&valid));
        for invalid in [
            format!("{valid}="),
            "A".repeat(HANDOFF_CHALLENGE_TEXT_BYTES - 1),
            format!("{}B", "A".repeat(HANDOFF_CHALLENGE_TEXT_BYTES - 1)),
            format!("{}+", "A".repeat(HANDOFF_CHALLENGE_TEXT_BYTES - 1)),
            format!("{}-", "A".repeat(HANDOFF_CHALLENGE_TEXT_BYTES - 1)),
        ] {
            assert!(!is_canonical_challenge(&invalid), "accepted {invalid:?}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn challenge_response_is_strict_and_phase_bound() {
        let challenge = "A".repeat(HANDOFF_CHALLENGE_TEXT_BYTES);
        let valid = json!({
            "id": "coderouter-handoff-begin",
            "ok": true,
            "result": {
                "protocolVersion": SOCKET_PROTOCOL_VERSION,
                "challenge": challenge.clone(),
            },
        });
        let parsed = parse_socket_challenge(valid.to_string().as_bytes()).unwrap();
        assert_eq!(parsed.as_str(), challenge);
        for padded in [
            format!(" {valid}"),
            format!("{valid} "),
            format!("\t{valid}"),
            format!("{valid}\r"),
        ] {
            assert!(parse_socket_challenge(padded.as_bytes()).is_err());
        }

        for invalid in [
            json!({
                "id": "coderouter-handoff",
                "ok": true,
                "result": { "protocolVersion": 2, "challenge": "A".repeat(43) },
            }),
            json!({
                "id": "coderouter-handoff-begin",
                "ok": true,
                "result": { "protocolVersion": 1, "challenge": "A".repeat(43) },
            }),
            json!({
                "id": "coderouter-handoff-begin",
                "ok": true,
                "result": {
                    "protocolVersion": 2,
                    "challenge": "A".repeat(43),
                    "extra": true,
                },
            }),
            json!({
                "id": "coderouter-handoff-begin",
                "ok": false,
                "error": { "code": "denied" },
            }),
        ] {
            let error = parse_socket_challenge(invalid.to_string().as_bytes()).unwrap_err();
            assert_eq!(error.to_string(), "coderouter handoff response is invalid");
        }
    }

    #[cfg(unix)]
    #[test]
    fn legacy_single_step_grant_and_wrong_complete_id_are_rejected() {
        let grant = json!({
            "ok": true,
            "result": {
                "teamId": "team-handoff",
                "lease": format!("crh_{}", "B".repeat(43)),
                "expiresAt": "2099-08-13T12:00:00Z",
            },
        });
        for id in ["coderouter-handoff", "coderouter-handoff-begin"] {
            let mut response = grant.clone();
            response["id"] = json!(id);
            let error = parse_socket_grant(
                response.to_string().as_bytes(),
                Some(&team_binding("team-handoff")),
            )
            .unwrap_err();
            assert_eq!(error.to_string(), "coderouter handoff response is invalid");
        }
    }

    #[cfg(unix)]
    #[test]
    fn complete_response_rejects_surrounding_whitespace() {
        let response = json!({
            "id": "coderouter-handoff-complete",
            "ok": true,
            "result": {
                "teamId": "team-handoff",
                "lease": format!("crh_{}", "B".repeat(43)),
                "expiresAt": "2099-08-13T12:00:00Z",
            },
        });
        let binding = team_binding("team-handoff");
        for padded in [format!(" {response}"), format!("{response} ")] {
            assert!(parse_socket_grant(padded.as_bytes(), Some(&binding)).is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn team_id_uses_explicit_unicode_control_categories() {
        for character in [
            '\u{200b}',
            '\u{200e}',
            '\u{2060}',
            '\u{feff}',
            '\u{1d173}',
            '\u{e0001}',
        ] {
            assert!(is_protocol_control(character));
            assert!(!is_valid_team_id(&format!("team{character}id")));
        }
        for character in ['\u{e0101}', '\u{e0201}'] {
            assert!(!is_protocol_control(character));
            assert!(is_valid_team_id(&format!("team{character}id")));
        }
    }

    #[test]
    fn hidden_form_requires_exact_prefix_and_binding() {
        let binding = team_binding("team-handoff");
        let args = vec![
            std::ffi::OsString::from(HIDDEN_HANDOFF_COMMAND),
            std::ffi::OsString::from("/tmp/cmux.sock"),
            std::ffi::OsString::from(binding),
            std::ffi::OsString::from("--"),
            std::ffi::OsString::from("codex"),
            std::ffi::OsString::from("exec"),
        ];
        let (_, rewritten) = parse_hidden_args(&args).unwrap().unwrap();
        assert_eq!(rewritten[0].to_str(), Some("codex"));
    }

    #[test]
    fn hidden_form_rejects_invalid_shapes() {
        let binding = team_binding("team-handoff");
        let short_binding = "0".repeat(63);
        let valid = [
            HIDDEN_HANDOFF_COMMAND,
            "/tmp/cmux.sock",
            binding.as_str(),
            "--",
            "codex",
        ];
        for invalid in [
            valid[..4].to_vec(),
            vec![valid[0], "relative.sock", valid[2], valid[3], valid[4]],
            vec![
                valid[0],
                valid[1],
                short_binding.as_str(),
                valid[3],
                valid[4],
            ],
            vec![valid[0], valid[1], valid[2], "-", valid[4]],
            vec![valid[0], valid[1], valid[2], valid[3], "accounts"],
        ] {
            let args = invalid
                .into_iter()
                .map(std::ffi::OsString::from)
                .collect::<Vec<_>>();
            assert!(parse_hidden_args(&args).is_err());
        }
    }

    #[test]
    fn rejects_relative_socket_path() {
        assert!(validate_socket_path(Path::new("relative.sock")).is_err());
        let maximum = format!("/{}", "a".repeat(102));
        let oversized = format!("/{}", "a".repeat(103));
        assert_eq!(maximum.len(), 103);
        assert!(validate_socket_path(Path::new(&maximum)).is_ok());
        assert_eq!(oversized.len(), 104);
        assert!(validate_socket_path(Path::new(&oversized)).is_err());
        for character in [
            '\u{200b}',
            '\u{200e}',
            '\u{2060}',
            '\u{feff}',
            '\u{1d173}',
            '\u{e0001}',
        ] {
            assert!(validate_socket_path(Path::new(&format!("/tmp/a{character}b"))).is_err());
        }
        for character in ['\u{e0101}', '\u{e0201}'] {
            assert!(validate_socket_path(Path::new(&format!("/tmp/a{character}b"))).is_ok());
        }
    }

    #[cfg(unix)]
    #[test]
    fn mock_socket_sends_bounded_v2_request_and_reads_strict_grant() {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixListener;
        use tempfile::TempDir;

        let directory = TempDir::new().unwrap();
        let path = directory.path().join("handoff.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let binding = team_binding("team-handoff");
        let worker = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let request: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(
                request,
                json!({
                    "id": "coderouter-handoff-begin",
                    "method": "coderouter.handoff.begin",
                    "params": { "protocolVersion": SOCKET_PROTOCOL_VERSION },
                })
            );
            let challenge = "A".repeat(HANDOFF_CHALLENGE_TEXT_BYTES);
            let begin_response = json!({
                "id": "coderouter-handoff-begin",
                "ok": true,
                "result": {
                    "protocolVersion": SOCKET_PROTOCOL_VERSION,
                    "challenge": challenge,
                }
            });
            writeln!(stream, "{begin_response}").unwrap();
            line.clear();
            reader.read_line(&mut line).unwrap();
            let complete_request: serde_json::Value = serde_json::from_str(&line).unwrap();
            assert_eq!(
                complete_request,
                json!({
                    "id": "coderouter-handoff-complete",
                    "method": "coderouter.handoff.complete",
                    "params": {
                        "protocolVersion": SOCKET_PROTOCOL_VERSION,
                        "challenge": "A".repeat(HANDOFF_CHALLENGE_TEXT_BYTES),
                    },
                })
            );
            let response = json!({
                "id": "coderouter-handoff-complete",
                "ok": true,
                "result": {
                    "teamId": "team-handoff",
                    "lease": format!("crh_{}", "B".repeat(43)),
                    "expiresAt": "2099-08-13T12:00:00.000Z",
                }
            });
            writeln!(stream, "{response}").unwrap();
            std::thread::sleep(std::time::Duration::from_millis(50));
        });
        let lease = read_socket(&path, Some(&binding));
        worker.join().unwrap();
        let lease = lease.unwrap();
        assert!(is_valid_lease(&lease));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_socket_grant_without_binding_match() {
        let lease = format!("crh_{}", "B".repeat(43));
        let body = format!(
            "{{\"id\":\"coderouter-handoff-complete\",\"ok\":true,\"result\":{{\"teamId\":\"team-handoff\",\"lease\":\"crh_{}\",\"expiresAt\":\"2099-08-13T12:00:00Z\"}}}}",
            "B".repeat(43)
        );
        let error = parse_socket_grant(body.as_bytes(), Some(&"0".repeat(64))).unwrap_err();
        assert!(!error.to_string().contains(&lease));
        assert!(!error.to_string().contains("team-handoff"));
    }

    #[cfg(unix)]
    #[test]
    fn socket_reader_rejects_extra_frame_data() {
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        use std::time::Duration;

        let (mut client, mut server) = UnixStream::pair().unwrap();
        server.write_all(b"{}\n{}\n").unwrap();
        let error =
            read_socket_frame(&mut client, Instant::now() + Duration::from_secs(1)).unwrap_err();
        assert!(error.to_string().contains("extra frame data"));
    }

    #[cfg(unix)]
    #[test]
    fn final_socket_reader_rejects_delayed_extra_frame_data() {
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        use std::time::Duration;

        let (mut client, mut server) = UnixStream::pair().unwrap();
        let writer = std::thread::spawn(move || {
            server.write_all(b"{}\n").unwrap();
            std::thread::sleep(Duration::from_millis(50));
            server.write_all(b"late").unwrap();
        });
        let error = read_final_socket_frame(&mut client, Instant::now() + Duration::from_secs(1))
            .unwrap_err();
        writer.join().unwrap();
        assert!(error.to_string().contains("extra frame data"));
    }

    #[cfg(unix)]
    #[test]
    fn socket_frame_limit_includes_the_line_feed() {
        use std::io::Read;
        use std::os::unix::net::UnixStream;
        use std::time::Duration;

        let (mut client, mut server) = UnixStream::pair().unwrap();
        let payload = vec![b'a'; MAX_SOCKET_FRAME_BYTES - 1];
        write_framed_request(
            &mut client,
            payload.clone(),
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap();
        let mut received = vec![0_u8; MAX_SOCKET_FRAME_BYTES];
        server.read_exact(&mut received).unwrap();
        assert_eq!(&received[..MAX_SOCKET_FRAME_BYTES - 1], payload.as_slice());
        assert_eq!(received[MAX_SOCKET_FRAME_BYTES - 1], b'\n');

        let error = write_framed_request(
            &mut client,
            vec![b'a'; MAX_SOCKET_FRAME_BYTES],
            Instant::now() + Duration::from_secs(1),
        )
        .unwrap_err();
        assert!(error.to_string().contains("request is too large"));
    }

    #[cfg(unix)]
    #[test]
    fn socket_response_frame_limit_includes_the_line_feed() {
        use std::io::Write;
        use std::os::unix::net::UnixStream;
        use std::time::Duration;

        let (mut client, mut server) = UnixStream::pair().unwrap();
        let payload = vec![b'a'; MAX_SOCKET_FRAME_BYTES - 1];
        server.write_all(&payload).unwrap();
        server.write_all(b"\n").unwrap();
        let response =
            read_socket_frame(&mut client, Instant::now() + Duration::from_secs(1)).unwrap();
        assert_eq!(response.as_slice(), payload.as_slice());

        let (mut client, mut server) = UnixStream::pair().unwrap();
        server
            .write_all(&vec![b'a'; MAX_SOCKET_FRAME_BYTES])
            .unwrap();
        server.write_all(b"\n").unwrap();
        let error =
            read_socket_frame(&mut client, Instant::now() + Duration::from_secs(1)).unwrap_err();
        assert!(error.to_string().contains("response is too large"));
    }
}
