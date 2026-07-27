//! Process creation coordination shared by every cmux-tui runtime crate.

use std::io;
use std::process::{Child, Command};

#[cfg(target_os = "macos")]
static PROCESS_CREATION_BARRIER: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Holds the process-wide child-creation barrier.
///
/// macOS cannot create every socket descriptor with close-on-exec set
/// atomically. Socket setup holds this guard until `FD_CLOEXEC` is set, while
/// every child launch holds the same guard until the child exists.
/// Library-backed process launch paths, such as PTY creation, must acquire
/// this guard around their spawn call.
#[must_use = "dropping the guard releases process creation"]
pub struct ProcessCreationGuard {
    #[cfg(target_os = "macos")]
    _guard: std::sync::MutexGuard<'static, ()>,
}

impl ProcessCreationGuard {
    pub fn acquire() -> Self {
        #[cfg(target_os = "macos")]
        {
            let guard =
                PROCESS_CREATION_BARRIER.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            Self { _guard: guard }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self {}
        }
    }
}

/// Spawn a child while excluding non-atomic close-on-exec descriptor setup.
pub fn spawn(command: &mut Command) -> io::Result<Child> {
    let _guard = ProcessCreationGuard::acquire();
    command.spawn()
}

/// Unix socket operations whose descriptor creation is coordinated with
/// process launch on macOS.
#[cfg(unix)]
pub mod unix {
    use std::io;
    #[cfg(target_os = "macos")]
    use std::os::fd::AsRawFd;
    use std::os::unix::net::{SocketAddr, UnixListener, UnixStream};
    use std::path::Path;

    use super::ProcessCreationGuard;

    /// Bind a Unix listener without exposing its descriptor to a concurrent
    /// child launch.
    pub fn bind_listener(path: impl AsRef<Path>) -> io::Result<UnixListener> {
        let _guard = ProcessCreationGuard::acquire();
        UnixListener::bind(path)
    }

    /// Connect a Unix stream without exposing its descriptor to a concurrent
    /// child launch.
    pub fn connect_stream(path: impl AsRef<Path>) -> io::Result<UnixStream> {
        #[cfg(target_os = "macos")]
        {
            let address = socket2::SockAddr::unix(path)?;
            let socket = {
                let _guard = ProcessCreationGuard::acquire();
                socket2::Socket::new(socket2::Domain::UNIX, socket2::Type::STREAM, None)?
            };
            socket.connect(&address)?;
            Ok(socket.into())
        }
        #[cfg(not(target_os = "macos"))]
        {
            UnixStream::connect(path)
        }
    }

    /// Create a connected Unix stream pair without exposing either descriptor
    /// to a concurrent child launch.
    pub fn pair_stream() -> io::Result<(UnixStream, UnixStream)> {
        let _guard = ProcessCreationGuard::acquire();
        UnixStream::pair()
    }

    /// Clone a Unix stream without exposing the duplicate descriptor to a
    /// concurrent child launch.
    pub fn clone_stream(stream: &UnixStream) -> io::Result<UnixStream> {
        let _guard = ProcessCreationGuard::acquire();
        stream.try_clone()
    }

    /// Clone a Unix listener without exposing the duplicate descriptor to a
    /// concurrent child launch.
    pub fn clone_listener(listener: &UnixListener) -> io::Result<UnixListener> {
        let _guard = ProcessCreationGuard::acquire();
        listener.try_clone()
    }

    /// Accept a Unix stream without exposing the accepted descriptor to a
    /// concurrent child launch.
    pub fn accept_stream(listener: &UnixListener) -> io::Result<(UnixStream, SocketAddr)> {
        #[cfg(target_os = "macos")]
        {
            accept_macos(listener.as_raw_fd(), || listener.accept())
        }
        #[cfg(not(target_os = "macos"))]
        {
            listener.accept()
        }
    }

    #[cfg(target_os = "macos")]
    pub(super) fn accept_macos<T>(
        descriptor: libc::c_int,
        mut accept: impl FnMut() -> io::Result<T>,
    ) -> io::Result<T> {
        loop {
            let blocking = descriptor_is_blocking(descriptor)?;
            if blocking {
                wait_until_readable(descriptor)?;
            }
            let _guard = ProcessCreationGuard::acquire();
            match accept() {
                Err(error)
                    if blocking
                        && matches!(
                            error.kind(),
                            io::ErrorKind::Interrupted | io::ErrorKind::WouldBlock
                        ) => {}
                result => return result,
            }
        }
    }

    #[cfg(target_os = "macos")]
    fn descriptor_is_blocking(descriptor: libc::c_int) -> io::Result<bool> {
        // SAFETY: F_GETFL only reads flags from this valid listener descriptor.
        let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFL) };
        if flags < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(flags & libc::O_NONBLOCK == 0)
    }

    #[cfg(target_os = "macos")]
    fn wait_until_readable(descriptor: libc::c_int) -> io::Result<()> {
        loop {
            let mut poll_descriptor =
                libc::pollfd { fd: descriptor, events: libc::POLLIN, revents: 0 };
            // SAFETY: poll_descriptor points to one initialized pollfd for
            // the duration of the blocking readiness wait.
            let result = unsafe { libc::poll(&raw mut poll_descriptor, 1, -1) };
            if result > 0 {
                if poll_descriptor.revents & libc::POLLNVAL != 0 {
                    return Err(io::Error::from_raw_os_error(libc::EBADF));
                }
                return Ok(());
            }
            if result == 0 {
                continue;
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

/// TCP socket operations whose descriptor creation is coordinated with
/// process launch on macOS.
pub mod tcp {
    use std::io;
    use std::net::{SocketAddr, TcpListener, TcpStream};
    use std::time::Duration;

    use super::ProcessCreationGuard;

    /// Bind a TCP listener without exposing its descriptor to a concurrent
    /// child launch.
    pub fn bind_listener(address: SocketAddr) -> io::Result<TcpListener> {
        let _guard = ProcessCreationGuard::acquire();
        TcpListener::bind(address)
    }

    /// Connect a TCP stream without exposing its descriptor to a concurrent
    /// child launch.
    pub fn connect_stream(address: SocketAddr) -> io::Result<TcpStream> {
        #[cfg(target_os = "macos")]
        {
            let socket = new_stream_socket(address)?;
            socket.connect(&address.into())?;
            Ok(socket.into())
        }
        #[cfg(not(target_os = "macos"))]
        {
            TcpStream::connect(address)
        }
    }

    /// Connect a bounded TCP stream without exposing its descriptor to a
    /// concurrent child launch.
    pub fn connect_stream_timeout(
        address: &SocketAddr,
        timeout: Duration,
    ) -> io::Result<TcpStream> {
        #[cfg(target_os = "macos")]
        {
            let socket = new_stream_socket(*address)?;
            socket.connect_timeout(&(*address).into(), timeout)?;
            Ok(socket.into())
        }
        #[cfg(not(target_os = "macos"))]
        {
            TcpStream::connect_timeout(address, timeout)
        }
    }

    /// Clone a TCP stream without exposing the duplicate descriptor to a
    /// concurrent child launch.
    pub fn clone_stream(stream: &TcpStream) -> io::Result<TcpStream> {
        let _guard = ProcessCreationGuard::acquire();
        stream.try_clone()
    }

    /// Clone a TCP listener without exposing the duplicate descriptor to a
    /// concurrent child launch.
    pub fn clone_listener(listener: &TcpListener) -> io::Result<TcpListener> {
        let _guard = ProcessCreationGuard::acquire();
        listener.try_clone()
    }

    /// Accept a TCP stream without exposing the accepted descriptor to a
    /// concurrent child launch.
    pub fn accept_stream(listener: &TcpListener) -> io::Result<(TcpStream, SocketAddr)> {
        #[cfg(target_os = "macos")]
        {
            use std::os::fd::AsRawFd;

            super::unix::accept_macos(listener.as_raw_fd(), || listener.accept())
        }
        #[cfg(not(target_os = "macos"))]
        {
            listener.accept()
        }
    }

    #[cfg(target_os = "macos")]
    fn new_stream_socket(address: SocketAddr) -> io::Result<socket2::Socket> {
        let _guard = ProcessCreationGuard::acquire();
        socket2::Socket::new(
            socket2::Domain::for_address(address),
            socket2::Type::STREAM,
            Some(socket2::Protocol::TCP),
        )
    }
}
