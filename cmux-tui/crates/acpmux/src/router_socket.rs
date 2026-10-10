//! The local CodeRouter's admin socket (`<acpmux home>/router/router.sock`)
//! as routes.rs and `ensure_router` read it: std's unix stream on Unix;
//! on Windows `cmux::local_socket`, which refuses a socket file another
//! user owns (the router's listener refuses peers of another user).

#[cfg(unix)]
pub(crate) use std::os::unix::net::UnixStream;

/// Owner-only (mode 0600 on Unix, an owner-only access list on Windows)
/// for a file this user writes.
pub(crate) fn owner_only(path: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(windows)]
    if let Err(e) = crate::owner_only::restrict(path) {
        tracing::warn!("could not make {} owner-only: {e}", path.display());
    }
}

/// Windows: the router's local socket, connected only when our user owns
/// the socket file.
#[cfg(windows)]
pub(crate) struct UnixStream(cmux::local_socket::Stream);

#[cfg(windows)]
impl UnixStream {
    pub(crate) fn connect(path: impl AsRef<std::path::Path>) -> std::io::Result<Self> {
        cmux::local_socket::connect_same_user(path.as_ref()).map(Self)
    }

    pub(crate) fn set_read_timeout(
        &self,
        timeout: Option<std::time::Duration>,
    ) -> std::io::Result<()> {
        self.0.set_read_timeout(timeout)
    }

    pub(crate) fn try_clone(&self) -> std::io::Result<Self> {
        self.0.try_clone().map(Self)
    }
}

#[cfg(windows)]
impl std::io::Read for UnixStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0.read(buf)
    }
}

#[cfg(windows)]
impl std::io::Write for UnixStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.0.flush()
    }
}
