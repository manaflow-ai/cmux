//! The local control socket transport (moved out of platform.rs, behavior
//! unchanged).

use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::path::Path;
use std::time::Duration;

pub trait Stream: Read + Write + Send + Sync {
    fn try_clone_box(&self) -> io::Result<Box<dyn Stream>>;
    fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
    fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
    fn shutdown(&self, how: Shutdown) -> io::Result<()>;
    /// `token:<pid>.<pid version>` of the process at the other end of a
    /// local socket (request origin peer key); `None` where unknown.
    fn peer_process_key(&self) -> Option<String> {
        None
    }
    /// The peer's audit token (macOS Unix sockets only; P8 3b-2, prover A
    /// of `verified_app`). `None` elsewhere.
    fn peer_token(&self) -> Option<cmux_link::app_caller::PeerToken> {
        None
    }
}

pub struct Listener {
    inner: imp::Listener,
}

pub fn listen(path: &Path) -> io::Result<Listener> {
    imp::listen(path).map(|inner| Listener { inner })
}

pub fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
    imp::connect(path)
}

/// Connect and refuse a listener that runs as another user before the
/// caller writes anything. Windows sockets report no listener credentials:
/// there the socket file must be owned by our token user
/// (cmux-sdk local_socket).
pub fn connect_same_user(path: &Path) -> io::Result<Box<dyn Stream>> {
    imp::connect_same_user(path)
}

/// A listener serves its owner and root. Root can already open any
/// socket file, so refusing it would only get in the way of an admin.
#[cfg(unix)]
pub(crate) fn peer_may_connect(peer_uid: u32, owner_uid: u32) -> bool {
    peer_uid == owner_uid || peer_uid == 0
}

impl Listener {
    pub fn accept(&self) -> io::Result<Box<dyn Stream>> {
        self.inner.accept()
    }
}

#[cfg(unix)]
mod imp {
    use std::io;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::Path;
    use std::time::Duration;

    use super::Stream;

    pub(super) struct Listener {
        inner: UnixListener,
    }

    pub(super) fn listen(path: &Path) -> io::Result<Listener> {
        cmux_unix_socket::bind(path).map(|inner| Listener { inner })
    }

    pub(super) fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
        Ok(Box::new(cmux_unix_socket::connect(path)?))
    }

    pub(super) fn connect_same_user(path: &Path) -> io::Result<Box<dyn Stream>> {
        let stream = cmux_unix_socket::connect(path)?;
        crate::platform::require_unix_peer_uid(&stream, crate::platform::effective_uid())?;
        Ok(Box::new(stream))
    }

    impl Listener {
        pub(super) fn accept(&self) -> io::Result<Box<dyn Stream>> {
            let (stream, _) = self.inner.accept()?;
            let peer_uid = crate::platform::unix_peer_uid(&stream)?;
            if !super::peer_may_connect(peer_uid, crate::platform::effective_uid()) {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!("refused a socket client running as uid {peer_uid}"),
                ));
            }
            Ok(Box::new(stream))
        }
    }

    impl Stream for UnixStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn Stream>> {
            Ok(Box::new(self.try_clone()?))
        }

        fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
            UnixStream::set_read_timeout(self, timeout)
        }

        fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
            UnixStream::set_write_timeout(self, timeout)
        }

        fn shutdown(&self, how: std::net::Shutdown) -> io::Result<()> {
            UnixStream::shutdown(self, how)
        }

        fn peer_process_key(&self) -> Option<String> {
            crate::platform::peer_process::key(std::os::fd::AsRawFd::as_raw_fd(self))
        }

        fn peer_token(&self) -> Option<cmux_link::app_caller::PeerToken> {
            cmux_link::app_caller::peer_token(std::os::fd::AsRawFd::as_raw_fd(self))
        }
    }
}

#[cfg(windows)]
mod imp {
    //! The shared local-socket transport (cmux-sdk local_socket): every peer is
    //! checked (our user, not sandboxed), the socket file is owned by our
    //! token user, and `connect_same_user` refuses a socket file another
    //! user owns. The runtime directory is made owner-only by
    //! `server::prepare_runtime_socket_directory`.
    use std::io;
    use std::path::Path;
    use std::time::Duration;

    use super::Stream;
    use uds_windows::UnixStream;

    pub(super) struct Listener {
        inner: cmux::local_socket::Listener,
    }

    pub(super) fn listen(path: &Path) -> io::Result<Listener> {
        cmux::local_socket::listen_explicit(path).map(|inner| Listener { inner })
    }

    pub(super) fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
        Ok(Box::new(cmux::local_socket::connect(path)?))
    }

    pub(super) fn connect_same_user(path: &Path) -> io::Result<Box<dyn Stream>> {
        Ok(Box::new(cmux::local_socket::connect_same_user(path)?))
    }

    impl Listener {
        pub(super) fn accept(&self) -> io::Result<Box<dyn Stream>> {
            Ok(Box::new(self.inner.accept()?))
        }
    }

    impl Stream for UnixStream {
        fn try_clone_box(&self) -> io::Result<Box<dyn Stream>> {
            Ok(Box::new(self.try_clone()?))
        }

        fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
            UnixStream::set_read_timeout(self, timeout)
        }

        fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
            UnixStream::set_write_timeout(self, timeout)
        }

        fn shutdown(&self, how: std::net::Shutdown) -> io::Result<()> {
            UnixStream::shutdown(self, how)
        }
    }
}
