//! The local CodeRouter's admin socket (`cmux_coderouter::admin_socket_path`)
//! as routes.rs and `ensure_router` read it: std's unix stream on Unix;
//! on Windows `cmux::local_socket`, which refuses a socket file another
//! user owns (the router's listener refuses peers of another user).

#[cfg(unix)]
pub(crate) use std::os::unix::net::UnixStream;

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
