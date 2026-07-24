//! One-shot authenticated binary semantic-scene endpoints for the Mac mobile host.

use std::fs;
use std::io::{BufWriter, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use ghostty_vt::SceneSectionKind;

use crate::{
    PresentationId, SemanticSceneAttachmentOptions, SemanticSceneCaptureOptions,
    SemanticSceneEvent, SemanticSceneFrame, SemanticScenePresentationIdentity, Surface,
};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
const IO_TIMEOUT: Duration = Duration::from_secs(5);
const DISCONNECT_POLL: Duration = Duration::from_millis(250);
const AUTH_MAGIC: &[u8; 8] = b"CMXSCNA1";
const SCENE_MAGIC: &[u8; 8] = b"CMXSCN01";
const SCENE_VERSION: u8 = 1;
const SCENE_ENVELOPE_KIND: u8 = 2;
const TOKEN_LENGTH: usize = 32;

/// Path and bearer proof for one endpoint that accepts exactly one same-user client.
pub(crate) struct MobileSceneEndpointReceipt {
    pub path: PathBuf,
    pub token: String,
}

struct SocketPathGuard(PathBuf);

impl Drop for SocketPathGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

/// Captures a full scene atomically, then serves it and contiguous updates as binary records.
pub(crate) fn open_mobile_scene_endpoint(
    surface: Arc<Surface>,
    presentation_id: PresentationId,
    presentation_generation: u64,
    capture: SemanticSceneCaptureOptions,
) -> anyhow::Result<MobileSceneEndpointReceipt> {
    if presentation_id.as_uuid().is_nil() {
        anyhow::bail!("semantic scene presentation identity must be non-nil");
    }
    if presentation_generation == 0 {
        anyhow::bail!("semantic scene presentation generation must be nonzero");
    }
    let terminal = surface
        .semantic_scene_terminal_identity()
        .ok_or_else(|| anyhow::anyhow!("browser surfaces have no semantic terminal scene"))?;
    let mut options = SemanticSceneAttachmentOptions::new(
        terminal,
        SemanticScenePresentationIdentity { presentation_id, generation: presentation_generation },
    );
    options.capture = capture;
    let attachment = surface.attach_semantic_scene(options)?;

    let (listener, path) = bind_private_listener()?;
    let path_guard = SocketPathGuard(path.clone());
    let mut token = [0_u8; TOKEN_LENGTH];
    getrandom::fill(&mut token)
        .map_err(|error| anyhow::anyhow!("generate semantic scene endpoint token: {error}"))?;
    let encoded_token = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(token);

    std::thread::Builder::new().name("mux-mobile-scene-out".into()).spawn(move || {
        let _path_guard = path_guard;
        let _ = serve(listener, token, attachment);
    })?;

    Ok(MobileSceneEndpointReceipt { path, token: encoded_token })
}

fn bind_private_listener() -> anyhow::Result<(UnixListener, PathBuf)> {
    let directory = crate::platform::short_runtime_dir();
    crate::platform::ensure_private_directory(&directory)?;
    for _ in 0..4 {
        let path = directory.join(format!("terminal-scene-{}.sock", uuid::Uuid::new_v4().simple()));
        match UnixListener::bind(&path) {
            Ok(listener) => {
                set_close_on_exec(listener.as_raw_fd())?;
                fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
                return Ok((listener, path));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AddrInUse => continue,
            Err(error) => return Err(error.into()),
        }
    }
    anyhow::bail!("could not allocate a unique semantic scene endpoint")
}

fn serve(
    listener: UnixListener,
    token: [u8; TOKEN_LENGTH],
    attachment: crate::SemanticSceneAttachment,
) -> anyhow::Result<()> {
    wait_readable(listener.as_raw_fd(), CONNECT_TIMEOUT)?;
    let (mut stream, _) = listener.accept()?;
    set_close_on_exec(stream.as_raw_fd())?;
    validate_same_user(&stream)?;
    stream.set_read_timeout(Some(IO_TIMEOUT))?;
    stream.set_write_timeout(Some(IO_TIMEOUT))?;

    let mut auth = [0_u8; AUTH_MAGIC.len() + TOKEN_LENGTH];
    stream.read_exact(&mut auth)?;
    if &auth[..AUTH_MAGIC.len()] != AUTH_MAGIC
        || !constant_time_equal(&auth[AUTH_MAGIC.len()..], &token)
    {
        anyhow::bail!("semantic scene endpoint authentication failed");
    }

    let read_stream = stream.try_clone()?;
    let mut writer = BufWriter::new(stream);
    write_scene(&mut writer, &attachment.initial)?;
    loop {
        match attachment.events.recv_timeout(DISCONNECT_POLL) {
            Ok(SemanticSceneEvent::Scene(frame)) => write_scene(&mut writer, &frame)?,
            Ok(SemanticSceneEvent::Failed(error)) => {
                anyhow::bail!("semantic scene capture failed: {error}");
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if peer_disconnected(&read_stream)? {
                    return Ok(());
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
        }
    }
}

fn write_scene(
    writer: &mut BufWriter<UnixStream>,
    frame: &SemanticSceneFrame,
) -> std::io::Result<()> {
    let payload_length = u32::try_from(frame.len())
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "scene is too large"))?;
    writer.write_all(SCENE_MAGIC)?;
    writer.write_all(&[SCENE_VERSION, SCENE_ENVELOPE_KIND])?;
    writer.write_all(&0_u16.to_be_bytes())?;
    writer.write_all(&payload_length.to_be_bytes())?;
    writer.write_all(frame.terminal.terminal_id.as_uuid().as_bytes())?;
    writer.write_all(&frame.terminal.runtime_epoch.to_be_bytes())?;
    writer.write_all(&frame.content_sequence.to_be_bytes())?;
    writer.write_all(frame.presentation.presentation_id.as_uuid().as_bytes())?;
    writer.write_all(&frame.presentation.generation.to_be_bytes())?;
    writer.write_all(&frame.presentation_sequence.to_be_bytes())?;
    writer.write_all(&[match frame.canonical_kind {
        SceneSectionKind::Full => 1,
        SceneSectionKind::Delta => 2,
        SceneSectionKind::Unchanged => 3,
    }])?;
    writer.write_all(&[0_u8; 7])?;
    writer.write_all(frame.as_bytes())?;
    writer.flush()
}

fn wait_readable(descriptor: i32, timeout: Duration) -> std::io::Result<()> {
    let mut poll = libc::pollfd { fd: descriptor, events: libc::POLLIN, revents: 0 };
    let timeout_ms = i32::try_from(timeout.as_millis()).unwrap_or(i32::MAX);
    loop {
        let status = unsafe { libc::poll(&mut poll, 1, timeout_ms) };
        if status > 0 && poll.revents & libc::POLLIN != 0 {
            return Ok(());
        }
        if status == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "semantic scene endpoint connection deadline elapsed",
            ));
        }
        if status < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(if status < 0 {
            std::io::Error::last_os_error()
        } else {
            std::io::Error::new(
                std::io::ErrorKind::ConnectionAborted,
                "semantic scene endpoint listener closed",
            )
        });
    }
}

fn peer_disconnected(stream: &UnixStream) -> std::io::Result<bool> {
    let mut poll = libc::pollfd { fd: stream.as_raw_fd(), events: libc::POLLIN, revents: 0 };
    let status = unsafe { libc::poll(&mut poll, 1, 0) };
    if status < 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(status > 0 && poll.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0)
}

#[cfg(any(
    target_os = "macos",
    target_os = "freebsd",
    target_os = "openbsd",
    target_os = "netbsd",
    target_os = "dragonfly"
))]
fn validate_same_user(stream: &UnixStream) -> std::io::Result<()> {
    let mut user_id = 0;
    let mut group_id = 0;
    let status = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut user_id, &mut group_id) };
    if status != 0 {
        return Err(std::io::Error::last_os_error());
    }
    if user_id != unsafe { libc::geteuid() } {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "semantic scene endpoint peer has a different effective user",
        ));
    }
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn validate_same_user(stream: &UnixStream) -> std::io::Result<()> {
    use std::mem::{MaybeUninit, size_of};

    let mut credentials = MaybeUninit::<libc::ucred>::uninit();
    let mut length = size_of::<libc::ucred>() as libc::socklen_t;
    let status = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            credentials.as_mut_ptr().cast(),
            &mut length,
        )
    };
    if status != 0 {
        return Err(std::io::Error::last_os_error());
    }
    if length as usize != size_of::<libc::ucred>() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "semantic scene endpoint returned invalid peer credentials",
        ));
    }
    let credentials = unsafe { credentials.assume_init() };
    if credentials.uid != unsafe { libc::geteuid() } {
        return Err(std::io::Error::new(
            std::io::ErrorKind::PermissionDenied,
            "semantic scene endpoint peer has a different effective user",
        ));
    }
    Ok(())
}

fn set_close_on_exec(descriptor: i32) -> std::io::Result<()> {
    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
    if flags < 0 || unsafe { libc::fcntl(descriptor, libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .fold(0_u8, |difference, (left, right)| difference | (left ^ right))
            == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn authentication_comparison_checks_every_byte() {
        assert!(constant_time_equal(&[1, 2, 3], &[1, 2, 3]));
        assert!(!constant_time_equal(&[1, 2, 3], &[1, 2, 4]));
        assert!(!constant_time_equal(&[1, 2], &[1, 2, 3]));
    }

    #[test]
    fn endpoint_socket_name_fits_the_platform_limit() {
        let path = crate::platform::short_runtime_dir()
            .join(format!("terminal-scene-{}.sock", uuid::Uuid::new_v4().simple()));
        crate::platform::validate_unix_socket_path(std::path::Path::new(&path)).unwrap();
    }
}
