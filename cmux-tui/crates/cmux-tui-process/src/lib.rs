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

    /// Acquire the process barrier without exceeding an operation deadline.
    pub fn acquire_until(deadline: std::time::Instant) -> io::Result<Self> {
        #[cfg(target_os = "macos")]
        {
            loop {
                match PROCESS_CREATION_BARRIER.try_lock() {
                    Ok(guard) => return Ok(Self { _guard: guard }),
                    Err(std::sync::TryLockError::Poisoned(error)) => {
                        return Ok(Self { _guard: error.into_inner() });
                    }
                    Err(std::sync::TryLockError::WouldBlock) => {}
                }
                let remaining = deadline
                    .checked_duration_since(std::time::Instant::now())
                    .filter(|remaining| !remaining.is_zero())
                    .ok_or_else(|| {
                        io::Error::new(
                            io::ErrorKind::TimedOut,
                            "process creation barrier acquisition timed out",
                        )
                    })?;
                std::thread::sleep(remaining.min(std::time::Duration::from_millis(1)));
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = deadline;
            Ok(Self {})
        }
    }
}

/// Spawn a child while excluding non-atomic close-on-exec descriptor setup.
pub fn spawn(command: &mut Command) -> io::Result<Child> {
    let _guard = ProcessCreationGuard::acquire();
    command.spawn()
}

/// Spawn a child only while the process barrier deadline remains valid.
pub fn spawn_until(command: &mut Command, deadline: std::time::Instant) -> io::Result<Child> {
    let _guard = ProcessCreationGuard::acquire_until(deadline)?;
    if std::time::Instant::now() >= deadline {
        return Err(io::Error::new(io::ErrorKind::TimedOut, "process spawn deadline expired"));
    }
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
    #[cfg(target_os = "macos")]
    use std::time::Instant;

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
            let deadline = Instant::now() + timeout;
            let socket = new_stream_socket_until(*address, deadline)?;
            let remaining = deadline
                .checked_duration_since(Instant::now())
                .filter(|remaining| !remaining.is_zero())
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::TimedOut, "TCP connection timed out")
                })?;
            socket.connect_timeout(&(*address).into(), remaining)?;
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

    #[cfg(target_os = "macos")]
    fn new_stream_socket_until(
        address: SocketAddr,
        deadline: Instant,
    ) -> io::Result<socket2::Socket> {
        let _guard = ProcessCreationGuard::acquire_until(deadline)?;
        socket2::Socket::new(
            socket2::Domain::for_address(address),
            socket2::Type::STREAM,
            Some(socket2::Protocol::TCP),
        )
    }
}

/// Tokio socket operations coordinated with process launch on macOS.
///
/// Tokio and Mio cannot create or accept every macOS socket with
/// close-on-exec set atomically. These helpers hold the same process-wide
/// guard used by child launch only around descriptor creation and registration.
pub mod tokio_net {
    use std::io;
    use std::net::SocketAddr;

    use tokio::net::{TcpListener, TcpSocket, TcpStream};

    use super::ProcessCreationGuard;

    /// Bind and register a Tokio TCP listener without an inheritance window.
    pub fn bind_tcp_listener(address: SocketAddr) -> io::Result<TcpListener> {
        let listener = super::tcp::bind_listener(address)?;
        listener.set_nonblocking(true)?;
        TcpListener::from_std(listener)
    }

    /// Connect to the first reachable TCP address without an inheritance window.
    pub async fn connect_tcp_stream(addresses: &[SocketAddr]) -> io::Result<TcpStream> {
        let mut last_error = None;
        for &address in addresses {
            let socket = {
                let _guard = ProcessCreationGuard::acquire();
                if address.is_ipv4() { TcpSocket::new_v4() } else { TcpSocket::new_v6() }
            }?;
            match socket.connect(address).await {
                Ok(stream) => return Ok(stream),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.unwrap_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "TCP address list is empty")
        }))
    }

    /// Accept a Tokio TCP stream without an inheritance window.
    pub async fn accept_tcp_stream(listener: &TcpListener) -> io::Result<(TcpStream, SocketAddr)> {
        #[cfg(target_os = "macos")]
        {
            std::future::poll_fn(|context| {
                let _guard = ProcessCreationGuard::acquire();
                listener.poll_accept(context)
            })
            .await
        }
        #[cfg(not(target_os = "macos"))]
        {
            listener.accept().await
        }
    }

    #[cfg(unix)]
    use std::path::Path;
    #[cfg(unix)]
    use tokio::net::{UnixListener, UnixStream};

    /// Bind and register a Tokio Unix listener without an inheritance window.
    #[cfg(unix)]
    pub fn bind_unix_listener(path: impl AsRef<Path>) -> io::Result<UnixListener> {
        let listener = super::unix::bind_listener(path)?;
        listener.set_nonblocking(true)?;
        UnixListener::from_std(listener)
    }

    /// Connect a Tokio Unix stream without an inheritance window.
    #[cfg(unix)]
    pub async fn connect_unix_stream(path: impl AsRef<Path>) -> io::Result<UnixStream> {
        #[cfg(target_os = "macos")]
        {
            let address = socket2::SockAddr::unix(path)?;
            let (stream, pending) = {
                let _guard = ProcessCreationGuard::acquire();
                let socket =
                    socket2::Socket::new(socket2::Domain::UNIX, socket2::Type::STREAM, None)?;
                socket.set_nonblocking(true)?;
                let pending = match socket.connect(&address) {
                    Ok(()) => false,
                    Err(error) if connect_is_pending(&error) => true,
                    Err(error) => return Err(error),
                };
                let stream: std::os::unix::net::UnixStream = socket.into();
                (stream, pending)
            };
            let stream = UnixStream::from_std(stream)?;
            if pending {
                stream.writable().await?;
                if let Some(error) = stream.take_error()? {
                    return Err(error);
                }
            }
            Ok(stream)
        }
        #[cfg(not(target_os = "macos"))]
        {
            UnixStream::connect(path).await
        }
    }

    /// Accept a Tokio Unix stream without an inheritance window.
    #[cfg(unix)]
    pub async fn accept_unix_stream(
        listener: &UnixListener,
    ) -> io::Result<(UnixStream, tokio::net::unix::SocketAddr)> {
        #[cfg(target_os = "macos")]
        {
            std::future::poll_fn(|context| {
                let _guard = ProcessCreationGuard::acquire();
                listener.poll_accept(context)
            })
            .await
        }
        #[cfg(not(target_os = "macos"))]
        {
            listener.accept().await
        }
    }

    #[cfg(target_os = "macos")]
    fn connect_is_pending(error: &io::Error) -> bool {
        error.kind() == io::ErrorKind::WouldBlock
            || matches!(
                error.raw_os_error(),
                Some(libc::EINPROGRESS | libc::EALREADY | libc::EWOULDBLOCK)
            )
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use std::time::Duration;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn tokio_tcp_connect_waits_for_process_creation_barrier() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (held_sender, held_receiver) = std::sync::mpsc::channel();
        let (release_sender, release_receiver) = std::sync::mpsc::channel();
        let holder = std::thread::spawn(move || {
            let _barrier = super::ProcessCreationGuard::acquire();
            held_sender.send(()).unwrap();
            release_receiver.recv().unwrap();
        });
        held_receiver
            .recv_timeout(Duration::from_secs(1))
            .expect("process creation barrier was not acquired");

        let connect =
            tokio::spawn(async move { super::tokio_net::connect_tcp_stream(&[address]).await });
        tokio::time::sleep(Duration::from_millis(250)).await;
        let completed_while_barrier_held = connect.is_finished();
        release_sender.send(()).unwrap();
        holder.join().unwrap();

        let stream = tokio::time::timeout(Duration::from_secs(5), connect)
            .await
            .expect("TCP connect did not resume after the process barrier was released")
            .unwrap()
            .unwrap();
        let (peer, _) = listener.accept().unwrap();
        drop(peer);
        drop(stream);
        assert!(
            !completed_while_barrier_held,
            "TCP connect created a socket while a concurrent process could inherit it"
        );
    }
}
