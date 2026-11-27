//! Binding the daemon's Unix socket owner-only, and who may connect to it.

use super::*;

/// Bind the daemon socket (mode 0600), refusing to steal a live one.
#[cfg(unix)]
pub async fn bind_unix(path: &std::path::Path) -> Result<UnixListener> {
    bind_unix_with(path, |_| false).await
}

/// The daemon's own bind of its socket, holding this home's lock. A connect that succeeds is no
/// other daemon when the process listening behind it is one `ours_or_gone` names (this process,
/// the daemon it took over from, or a process that no longer runs): that socket is replaced.
/// Any other listener is refused as [`bind_unix`] refuses it.
#[cfg(unix)]
pub(crate) async fn bind_daemon_unix(
    path: &std::path::Path,
    ours_or_gone: fn(u32) -> bool,
) -> Result<UnixListener> {
    bind_unix_with(path, ours_or_gone).await
}

#[cfg(unix)]
async fn bind_unix_with(
    path: &std::path::Path,
    replaceable: fn(u32) -> bool,
) -> Result<UnixListener> {
    crate::config::refuse_lost_home(&crate::config::home())?;
    // A configured path longer than sun_path fails here with the path and
    // the limit, never as a bare bind error.
    cmux_unix_socket::check_path(path)?;
    if let Some(parent) = path.parent() {
        // Owner-only when created here, like the /tmp fallback directory; acpmux's own directory
        // that already exists wider is narrowed to it too ([`tighten_socket_dir`]).
        crate::home_fs::create_dir_all(parent, 0o700)?;
        tighten_socket_dir(parent)?;
    }
    if path.exists() {
        // Refuse to steal a live socket.
        if let Ok(stream) = tokio::net::UnixStream::connect(path).await {
            // The process that called listen on it, whichever process holds a copy now.
            let pid = stream.peer_cred().ok().and_then(|c| c.pid());
            drop(stream);
            match pid.and_then(|p| u32::try_from(p).ok()) {
                Some(pid) if replaceable(pid) => tracing::warn!(
                    pid,
                    "{} answers from a listener that is no other daemon; replacing it",
                    path.display()
                ),
                _ => anyhow::bail!("another acpmux daemon owns {}", path.display()),
            }
        }
        // A failed connect is not a dead socket: a live daemon whose accept queue is full
        // refuses it too. Only the holder of the lock that serves it may remove it.
        if let Some(pid) = crate::daemon::socket_held_by_other(path) {
            anyhow::bail!(
                "the acpmux daemon pid {pid} holds the lock that serves {}; leaving its socket in place",
                path.display()
            );
        }
        crate::config::refuse_lost_home(&crate::config::home())?;
        crate::home_fs::remove_file(path)?;
    }
    crate::config::refuse_lost_home(&crate::config::home())?;
    let listener = bind_owner_only(path)?;
    tracing::info!("listening on {}", path.display());
    Ok(listener)
}

/// Binds `path` so nobody but this user can ever connect, without touching the process umask:
/// the umask is process-wide, so setting it for one bind made a folder another thread created
/// meanwhile 0600, which nothing can enter (two hub_carrier pipe tests failed with "bind
/// .../acpmux.sock: Permission denied" that way). The socket is bound inside a fresh 0700
/// folder next to `path`, made 0600 there and renamed into place; a bound socket keeps working
/// under its new name. A staging path too long for `sun_path` binds in place, where the 0600
/// chmod follows at once and the peer check at accept ([`peer_uid_allowed`]) holds meanwhile.
#[cfg(unix)]
fn bind_owner_only(path: &std::path::Path) -> Result<UnixListener> {
    use std::os::unix::fs::PermissionsExt;
    static NEXT: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let owner_only = || std::fs::Permissions::from_mode(0o600);
    let parent = path.parent().filter(|p| !p.as_os_str().is_empty());
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stage = parent.map(|p| p.join(format!(".b{:x}{n:x}", std::process::id())));
    let staged = stage.as_ref().map(|s| s.join("s"));
    let fits = staged.as_ref().is_some_and(|s| cmux_unix_socket::check_path(s).is_ok());
    let (Some(stage), Some(staged), true) = (stage, staged, fits) else {
        let listener =
            UnixListener::bind(path).with_context(|| format!("bind {}", path.display()))?;
        crate::home_fs::set_permissions(path, owner_only())?;
        return Ok(listener);
    };
    crate::home_fs::create_dir(&stage, 0o700)
        .with_context(|| format!("create {}", stage.display()))?;
    let bound = (|| -> Result<UnixListener> {
        // A umask set elsewhere can leave the folder without its search bit; 0700 whatever it was.
        crate::home_fs::set_permissions(&stage, std::fs::Permissions::from_mode(0o700))?;
        let listener =
            UnixListener::bind(&staged).with_context(|| format!("bind {}", path.display()))?;
        crate::home_fs::set_permissions(&staged, owner_only())?;
        crate::home_fs::rename(&staged, path)
            .with_context(|| format!("move the socket to {}", path.display()))?;
        Ok(listener)
    })();
    let _ = crate::home_fs::remove_file(&staged);
    let _ = crate::home_fs::remove_dir(&stage);
    bound
}

/// Narrows `dir`, the daemon socket's directory, to 0700 when it is acpmux's own (its home, or a
/// directory named `acpmux...` such as the `/tmp/acpmux-UID` fallback) and this user owns it:
/// `create_dir_all` leaves a directory that already exists as it was. A directory the person named
/// with `ACPMUX_SOCKET` (their home, a project) is never changed; the socket's own mode and the
/// peer check at accept ([`peer_uid_allowed`]) hold there.
#[cfg(unix)]
pub(super) fn tighten_socket_dir(dir: &std::path::Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let ours = dir == crate::config::home().as_path()
        || dir.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("acpmux"));
    if !ours {
        return Ok(());
    }
    let Ok(meta) = std::fs::symlink_metadata(dir) else { return Ok(()) };
    // SAFETY: geteuid has no preconditions and cannot fail.
    let own = unsafe { libc::geteuid() };
    if meta.is_dir() && meta.uid() == own && meta.mode() & 0o077 != 0 {
        let mode = meta.mode() & 0o700;
        crate::home_fs::set_permissions(dir, std::fs::Permissions::from_mode(mode))
            .with_context(|| format!("narrow {} to owner-only", dir.display()))?;
    }
    Ok(())
}

/// Whether a unix socket peer with `uid` may talk to the daemon running as `own`: this user, or
/// root (the Cloud machine's provisioner, `daemon/provision.rs`; root opens a 0600 socket anyway).
/// A peer whose uid cannot be read is refused.
#[cfg(unix)]
pub(crate) fn peer_uid_allowed(uid: Option<u32>, own: u32) -> bool {
    uid.is_some_and(|uid| uid == own || uid == 0)
}
