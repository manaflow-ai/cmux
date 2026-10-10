//! The local CodeRouter's admin socket (`<acpmux home>/router/router.sock`)
//! as routes.rs reads it: std's unix stream on Unix. The Windows port
//! (src/platform.rs) has no router socket yet, so there a connect always
//! fails and every route that needs the router is unavailable.

#[cfg(unix)]
pub(crate) use std::os::unix::net::UnixStream;

/// Owner-only mode (0600) for a file this user writes; Windows gets its
/// owner-only ACL in a later landing.
pub(crate) fn owner_only(path: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(not(unix))]
    let _ = path;
}

/// Windows: a stream that never connects (the router socket is not ported).
#[cfg(not(unix))]
pub(crate) struct UnixStream(std::convert::Infallible);

#[cfg(not(unix))]
impl UnixStream {
    pub(crate) fn connect(_path: impl AsRef<std::path::Path>) -> std::io::Result<Self> {
        Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            crate::platform::unsupported("the local CodeRouter's admin socket").to_string(),
        ))
    }

    pub(crate) fn set_read_timeout(
        &self,
        _timeout: Option<std::time::Duration>,
    ) -> std::io::Result<()> {
        match self.0 {}
    }

    pub(crate) fn try_clone(&self) -> std::io::Result<Self> {
        match self.0 {}
    }
}

#[cfg(not(unix))]
impl std::io::Read for UnixStream {
    fn read(&mut self, _buf: &mut [u8]) -> std::io::Result<usize> {
        match self.0 {}
    }
}

#[cfg(not(unix))]
impl std::io::Write for UnixStream {
    fn write(&mut self, _buf: &[u8]) -> std::io::Result<usize> {
        match self.0 {}
    }

    fn flush(&mut self) -> std::io::Result<()> {
        match self.0 {}
    }
}
