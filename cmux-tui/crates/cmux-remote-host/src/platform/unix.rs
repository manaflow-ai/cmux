//! Linux: `/proc` for process identity, Unix sockets in 0700 directories with
//! `SO_PEERCRED`, root-owned configuration, X11 or Wayland.

use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// The local stream both sockets use.
pub type LocalStream = tokio::net::UnixStream;

fn stat_fields(pid: u32) -> Option<Vec<String>> {
    let text = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // `pid (comm) state ppid ...`: comm may hold spaces and parentheses.
    let rest = &text[text.rfind(')')? + 1..];
    Some(rest.split_whitespace().map(str::to_owned).collect())
}

/// Start time in clock ticks after boot (`/proc/<pid>/stat` field 22).
pub fn process_start(pid: u32) -> Option<u64> {
    stat_fields(pid)?.get(19)?.parse().ok()
}

pub fn parent_pid(pid: u32) -> Option<u32> {
    stat_fields(pid)?.get(1)?.parse().ok()
}

pub fn process_exe(pid: u32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/exe")).ok()
}

/// Hashes the image the process runs (`/proc/<pid>/exe` opens that inode even
/// when the path was replaced or removed since).
pub fn process_exe_sha256(pid: u32) -> Option<String> {
    crate::wire::sha256_file(Path::new(&format!("/proc/{pid}/exe"))).ok()
}

pub fn process_uid(pid: u32) -> Option<u32> {
    std::fs::metadata(format!("/proc/{pid}")).ok().map(|meta| meta.uid())
}

pub fn my_uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

/// The peer of an accepted or connected socket: same uid and pid, from the kernel.
pub fn peer_of(stream: &LocalStream) -> Option<(bool, u32)> {
    let credentials = stream.peer_cred().ok()?;
    let pid = u32::try_from(credentials.pid()?).ok()?;
    Some((credentials.uid() == my_uid(), pid))
}

/// The process listening on a Unix socket: connect and read the peer pid.
/// Used for the daemon (the supervisor's peer must be the process serving the
/// daemon socket) and for acpmux daemons.
pub fn listener_pid(socket: &Path) -> Option<u32> {
    use std::os::unix::net::UnixStream;
    let stream = UnixStream::connect(socket).ok()?;
    let mut credentials: libc::ucred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    use std::os::fd::AsRawFd;
    // SAFETY: getsockopt into a correctly sized ucred.
    let ok = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&raw mut credentials).cast(),
            &mut length,
        )
    } == 0;
    (ok && credentials.uid == my_uid()).then(|| u32::try_from(credentials.pid).ok()).flatten()
}

/// Creates `dir` (and parents) and makes it 0700, owned by this user, not a symlink.
pub fn make_private_dir(dir: &Path) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    let meta = std::fs::symlink_metadata(dir).map_err(|error| format!("{}: {error}", dir.display()))?;
    if !meta.is_dir() || meta.uid() != my_uid() {
        return Err(format!("{} is not a directory of this user", dir.display()));
    }
    if meta.mode() & 0o777 != 0o700 {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("{}: {error}", dir.display()))?;
    }
    Ok(())
}

/// Writes `bytes` to `path` atomically, 0600, in a private directory.
pub fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let dir = path.parent().ok_or("no parent directory")?;
    make_private_dir(dir)?;
    let temporary = path.with_extension(format!("tmp{}", std::process::id()));
    let _ = std::fs::remove_file(&temporary);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temporary)
        .map_err(|error| format!("{}: {error}", temporary.display()))?;
    file.write_all(bytes).map_err(|error| format!("{}: {error}", temporary.display()))?;
    std::fs::rename(&temporary, path).map_err(|error| format!("{}: {error}", path.display()))
}

/// Reads a file of this user that no one else can read or write.
pub fn read_private(path: &Path) -> Result<Vec<u8>, String> {
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    let meta = file.metadata().map_err(|error| format!("{error}"))?;
    if !meta.is_file() || meta.uid() != my_uid() || meta.mode() & 0o077 != 0 {
        return Err(format!("{} is not private to this user", path.display()));
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|error| format!("{error}"))?;
    Ok(bytes)
}

/// Reads a file the machine's owner controls: root's, not writable by group
/// or others, in root's directories (config.rs).
pub fn read_owner_file(path: &Path) -> Result<String, String> {
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    let meta = file.metadata().map_err(|error| format!("{error}"))?;
    if !crate::config::unix_owner_file_ok(meta.uid(), meta.mode(), meta.is_file()) {
        return Err(format!(
            "{} must be a root-owned file that only root can write (owner uid {}, mode {:o})",
            path.display(),
            meta.uid(),
            meta.mode() & 0o7777
        ));
    }
    let mut dir = path.parent();
    while let Some(current) = dir {
        let meta = std::fs::symlink_metadata(current).map_err(|error| format!("{}: {error}", current.display()))?;
        if !meta.is_dir() || !crate::config::unix_owner_dir_ok(meta.uid(), meta.mode()) {
            return Err(format!("{} must be a root-owned directory that only root can write", current.display()));
        }
        dir = current.parent();
    }
    let mut text = String::new();
    file.read_to_string(&mut text).map_err(|error| format!("{}: {error}", path.display()))?;
    Ok(text)
}

/// A listening socket at `path` (0600) in its private directory.
pub fn listen(path: &Path) -> Result<tokio::net::UnixListener, String> {
    let dir = path.parent().ok_or("no socket directory")?;
    make_private_dir(dir)?;
    let _ = std::fs::remove_file(path);
    // SAFETY: umask only changes this process's file creation mask.
    let previous = unsafe { libc::umask(0o177) };
    let listener = tokio::net::UnixListener::bind(path);
    // SAFETY: as above.
    unsafe { libc::umask(previous) };
    let listener = listener.map_err(|error| format!("{}: {error}", path.display()))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).map_err(|error| format!("{error}"))?;
    Ok(listener)
}

pub async fn accept(listener: &tokio::net::UnixListener) -> std::io::Result<LocalStream> {
    listener.accept().await.map(|(stream, _)| stream)
}

/// Connects to a local endpoint and checks that its server runs as this user.
pub async fn connect(path: &Path) -> Result<LocalStream, String> {
    let stream = LocalStream::connect(path).await.map_err(|error| format!("{}: {error}", path.display()))?;
    match peer_of(&stream) {
        Some((true, _)) => Ok(stream),
        _ => Err(format!("{} is served by another user", path.display())),
    }
}

/// The desktop this process can reach, for status: `x11` or `wayland`
/// (portal), or none (a headless box without a display).
pub fn display_kind() -> Option<&'static str> {
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some_and(|value| !value.is_empty());
    let x11 = std::env::var_os("DISPLAY").is_some_and(|value| !value.is_empty());
    let session = std::env::var("XDG_SESSION_TYPE").unwrap_or_default();
    if wayland && session != "x11" {
        Some("wayland")
    } else if x11 {
        Some("x11")
    } else {
        None
    }
}

/// `status.permissions` (docs/cmux-remote.md "Windows and Linux"): `portal`
/// on Wayland (granted once the restore token exists), `x11` on Xorg or Xvfb.
pub fn permissions(state_dir: &Path) -> Value {
    match display_kind() {
        Some("wayland") => {
            let token = portal_token_path(state_dir);
            json!({"display": "wayland", "portal": if token.is_file() { "granted" } else { "ask" }})
        }
        Some(_) => json!({"display": "x11", "x11": "granted"}),
        None => json!({"display": "none", "x11": "unavailable", "portal": "unavailable"}),
    }
}

/// Where upstream keeps the RemoteDesktop portal's restore token once the
/// worker runs with `XDG_CONFIG_HOME` in the host's private state.
pub fn portal_token_path(state_dir: &Path) -> PathBuf {
    xdg_config_home(state_dir).join("cua-driver").join("libei-persistent.token")
}

/// The worker's `XDG_CONFIG_HOME`: inside the host's 0700 state, so the
/// portal grant's restore token is the host's (0600), and the person is asked once.
pub fn xdg_config_home(state_dir: &Path) -> PathBuf {
    state_dir.join("xdg-config")
}

/// The desktop session's variables a worker needs (never cmux tokens).
pub const DESKTOP_ENV: &[&str] = &[
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_DESKTOP",
    "DESKTOP_SESSION",
    "DBUS_SESSION_BUS_ADDRESS",
    "HOME",
    "USER",
    "LOGNAME",
    "LANG",
    "LC_ALL",
];

/// Tells systemd the host serves (`Type=notify`): `READY=1` on `$NOTIFY_SOCKET`.
/// False when the host was not started by systemd.
pub fn notify_ready(_leaf: &str) -> bool {
    let Some(socket) = std::env::var_os("NOTIFY_SOCKET") else { return false };
    let socket = socket.to_string_lossy().into_owned();
    let sender = match std::os::unix::net::UnixDatagram::unbound() {
        Ok(sender) => sender,
        Err(_) => return false,
    };
    #[cfg(target_os = "linux")]
    if let Some(abstract_name) = socket.strip_prefix('@') {
        use std::os::linux::net::SocketAddrExt;
        return std::os::unix::net::SocketAddr::from_abstract_name(abstract_name.as_bytes())
            .and_then(|address| sender.send_to_addr(b"READY=1", &address))
            .is_ok();
    }
    sender.send_to(b"READY=1", &socket).is_ok()
}

/// Whether this machine has a graphical session with a polkit agent: GNOME,
/// KDE and the other desktops start one with the session; a headless box
/// (Xvfb, a container) has none, and polkit is then not offered.
pub fn has_polkit_agent() -> bool {
    display_kind().is_some()
        && std::env::var("XDG_SESSION_TYPE").is_ok_and(|kind| kind == "x11" || kind == "wayland")
        && std::path::Path::new("/run/dbus/system_bus_socket").exists()
}

/// Windows only.
pub fn interactive_session() -> Option<bool> {
    None
}
