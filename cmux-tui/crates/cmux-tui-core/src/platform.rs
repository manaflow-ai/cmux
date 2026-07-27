//! Platform decisions for cmux-tui.

use std::path::{Path, PathBuf};

pub mod transport {
    use std::io::{self, Read, Write};
    use std::net::Shutdown;
    use std::path::Path;
    use std::time::{Duration, Instant};

    pub trait Stream: Read + Write + Send + Sync {
        fn try_clone_box(&self) -> io::Result<Box<dyn Stream>>;
        fn read_timeout(&self) -> io::Result<Option<Duration>>;
        fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
        fn write_timeout(&self) -> io::Result<Option<Duration>>;
        fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()>;
        fn shutdown(&self, how: Shutdown) -> io::Result<()>;
        fn peer_process_id(&self) -> io::Result<Option<u32>> {
            Ok(None)
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

    pub fn connect_until(path: &Path, deadline: Instant) -> io::Result<Box<dyn Stream>> {
        imp::connect_until(path, deadline)
    }

    #[cfg(unix)]
    pub(crate) fn connect_unix_until(
        path: &Path,
        deadline: Instant,
    ) -> io::Result<std::os::unix::net::UnixStream> {
        imp::connect_unix_until(path, deadline)
    }

    impl Listener {
        pub fn accept(&self) -> io::Result<Box<dyn Stream>> {
            self.inner.accept()
        }
    }

    #[cfg(unix)]
    mod imp {
        use std::io;
        use std::mem::{offset_of, size_of};
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        use std::os::unix::ffi::OsStrExt;
        use std::os::unix::net::{UnixListener, UnixStream};
        use std::path::Path;
        use std::time::{Duration, Instant};

        use super::Stream;

        #[cfg(test)]
        type SocketCreatedHook = std::sync::Arc<dyn Fn(libc::c_int) + Send + Sync>;
        #[cfg(test)]
        static SOCKET_CREATED_HOOK: std::sync::OnceLock<
            std::sync::Mutex<Option<SocketCreatedHook>>,
        > = std::sync::OnceLock::new();

        pub(super) struct Listener {
            inner: UnixListener,
        }

        #[cfg(test)]
        pub(super) fn set_socket_created_hook(hook: Option<SocketCreatedHook>) {
            *SOCKET_CREATED_HOOK.get_or_init(Default::default).lock().unwrap() = hook;
        }

        #[cfg(target_os = "linux")]
        fn create_close_on_exec_socket() -> io::Result<OwnedFd> {
            // SAFETY: socket has no pointer arguments and returns a new owned
            // descriptor on success. SOCK_CLOEXEC sets the inheritance flag
            // atomically with descriptor creation.
            let descriptor =
                unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
            if descriptor < 0 {
                let error = io::Error::last_os_error();
                if matches!(error.raw_os_error(), Some(libc::EINVAL) | Some(libc::EPROTONOSUPPORT))
                {
                    return Err(io::Error::new(
                        io::ErrorKind::Unsupported,
                        format!("atomic close-on-exec sockets are unavailable: {error}"),
                    ));
                }
                return Err(error);
            }
            // SAFETY: descriptor is a fresh successful socket result and this
            // OwnedFd takes its sole ownership.
            let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
            #[cfg(test)]
            if let Some(hook) =
                SOCKET_CREATED_HOOK.get_or_init(Default::default).lock().unwrap().clone()
            {
                hook(descriptor.as_raw_fd());
            }
            Ok(descriptor)
        }

        #[cfg(target_os = "macos")]
        fn create_close_on_exec_socket() -> io::Result<OwnedFd> {
            let _process_creation = cmux_tui_process::ProcessCreationGuard::acquire();
            // macOS has no SOCK_CLOEXEC socket flag. Every cmux-tui process
            // launch shares this barrier, so no child can start until fcntl
            // marks the fresh descriptor close-on-exec.
            // SAFETY: socket has no pointer arguments and returns a new owned
            // descriptor on success.
            let descriptor = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
            if descriptor < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: descriptor is a fresh successful socket result and this
            // OwnedFd takes its sole ownership.
            let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
            #[cfg(test)]
            if let Some(hook) =
                SOCKET_CREATED_HOOK.get_or_init(Default::default).lock().unwrap().clone()
            {
                hook(descriptor.as_raw_fd());
            }
            // SAFETY: F_GETFD only reads flags from this valid descriptor.
            let descriptor_flags = unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_GETFD) };
            if descriptor_flags < 0 {
                return Err(io::Error::last_os_error());
            }
            // SAFETY: F_SETFD updates flags while the process barrier excludes
            // process creation from this setup window.
            if unsafe {
                libc::fcntl(
                    descriptor.as_raw_fd(),
                    libc::F_SETFD,
                    descriptor_flags | libc::FD_CLOEXEC,
                )
            } < 0
            {
                return Err(io::Error::last_os_error());
            }
            Ok(descriptor)
        }

        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        fn create_close_on_exec_socket() -> io::Result<OwnedFd> {
            Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "deadline sockets require atomic close-on-exec setup",
            ))
        }

        pub(super) fn listen(path: &Path) -> io::Result<Listener> {
            cmux_tui_process::unix::bind_listener(path).map(|inner| Listener { inner })
        }

        pub(super) fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
            Ok(Box::new(cmux_tui_process::unix::connect_stream(path)?))
        }

        pub(super) fn connect_until(path: &Path, deadline: Instant) -> io::Result<Box<dyn Stream>> {
            connect_unix_until(path, deadline).map(|stream| Box::new(stream) as Box<dyn Stream>)
        }

        pub(super) fn connect_unix_until(path: &Path, deadline: Instant) -> io::Result<UnixStream> {
            ensure_connect_time_remaining(deadline)?;
            let (address, address_len) = unix_socket_address(path)?;
            let descriptor = create_close_on_exec_socket()?;
            let stream = UnixStream::from(descriptor);
            stream.set_nonblocking(true)?;
            loop {
                ensure_connect_time_remaining(deadline)?;
                // SAFETY: address is an initialized sockaddr_un with its
                // exact kernel-visible length, and stream owns a valid
                // AF_UNIX socket.
                let connected = unsafe {
                    libc::connect(
                        stream.as_raw_fd(),
                        (&raw const address).cast::<libc::sockaddr>(),
                        address_len,
                    )
                };
                if connected == 0 {
                    break;
                }
                let error = io::Error::last_os_error();
                let code = error.raw_os_error();
                if retry_connect_after_would_block(code, deadline)? {
                    continue;
                }
                let pending = [
                    Some(libc::EAGAIN),
                    Some(libc::EINPROGRESS),
                    Some(libc::EWOULDBLOCK),
                    Some(libc::EALREADY),
                    Some(libc::EINTR),
                ]
                .contains(&code);
                if !pending {
                    return Err(error);
                }
                wait_for_connect(&stream, deadline)?;
                break;
            }
            stream.set_nonblocking(false)?;
            Ok(stream)
        }

        fn retry_connect_after_would_block(
            code: Option<i32>,
            deadline: Instant,
        ) -> io::Result<bool> {
            #[cfg(target_os = "linux")]
            if code == Some(libc::EAGAIN) || code == Some(libc::EWOULDBLOCK) {
                // Linux leaves a nonblocking AF_UNIX socket unconnected when
                // the listener queue is full. The socket still polls writable
                // with SO_ERROR zero, so retry connect instead of treating
                // writability as completion.
                let remaining = ensure_connect_time_remaining(deadline)?;
                std::thread::sleep(remaining.min(Duration::from_millis(5)));
                return Ok(true);
            }
            let _ = (code, deadline);
            Ok(false)
        }

        fn ensure_connect_time_remaining(deadline: Instant) -> io::Result<Duration> {
            deadline
                .checked_duration_since(Instant::now())
                .filter(|remaining| !remaining.is_zero())
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::TimedOut,
                        "transport connection exceeded its deadline",
                    )
                })
        }

        fn wait_for_connect(stream: &UnixStream, deadline: Instant) -> io::Result<()> {
            loop {
                let remaining = ensure_connect_time_remaining(deadline)?;
                let timeout_ms = remaining.as_millis().max(1).min(i32::MAX as u128) as i32;
                let mut descriptor =
                    libc::pollfd { fd: stream.as_raw_fd(), events: libc::POLLOUT, revents: 0 };
                // SAFETY: descriptor points to one initialized pollfd for the
                // duration of this call.
                let result = unsafe { libc::poll(&raw mut descriptor, 1, timeout_ms) };
                if result == 0 {
                    continue;
                }
                if result < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                if descriptor.revents & libc::POLLNVAL != 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "transport connection socket became invalid",
                    ));
                }
                let mut socket_error = 0;
                let mut socket_error_len =
                    libc::socklen_t::try_from(size_of::<libc::c_int>()).unwrap();
                // SAFETY: socket_error and its length describe a writable
                // c_int, and stream owns a valid socket descriptor.
                if unsafe {
                    libc::getsockopt(
                        stream.as_raw_fd(),
                        libc::SOL_SOCKET,
                        libc::SO_ERROR,
                        (&raw mut socket_error).cast(),
                        &raw mut socket_error_len,
                    )
                } != 0
                {
                    return Err(io::Error::last_os_error());
                }
                return if socket_error == 0 {
                    Ok(())
                } else {
                    Err(io::Error::from_raw_os_error(socket_error))
                };
            }
        }

        pub(super) fn unix_socket_address(
            path: &Path,
        ) -> io::Result<(libc::sockaddr_un, libc::socklen_t)> {
            const SUN_PATH_CAPACITY: usize =
                size_of::<libc::sockaddr_un>() - offset_of!(libc::sockaddr_un, sun_path);
            let path = path.as_os_str().as_bytes();
            if path.is_empty() || path.len() >= SUN_PATH_CAPACITY || path.contains(&0) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid transport Unix socket path",
                ));
            }
            // SAFETY: all-zero is a valid starting representation for
            // sockaddr_un; family, path, and platform length are set below.
            let mut address = unsafe { std::mem::zeroed::<libc::sockaddr_un>() };
            address.sun_family = libc::AF_UNIX as libc::sa_family_t;
            for (destination, source) in address.sun_path.iter_mut().zip(path) {
                *destination = *source as libc::c_char;
            }
            let address_len = offset_of!(libc::sockaddr_un, sun_path) + path.len() + 1;
            #[cfg(any(
                target_os = "dragonfly",
                target_os = "freebsd",
                target_os = "macos",
                target_os = "netbsd",
                target_os = "openbsd"
            ))]
            {
                address.sun_len = u8::try_from(address_len).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "transport Unix socket path is too long",
                    )
                })?;
            }
            Ok((
                address,
                libc::socklen_t::try_from(address_len).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "transport Unix socket path is too long",
                    )
                })?,
            ))
        }

        impl Listener {
            pub(super) fn accept(&self) -> io::Result<Box<dyn Stream>> {
                let (stream, _) = cmux_tui_process::unix::accept_stream(&self.inner)?;
                Ok(Box::new(stream))
            }
        }

        impl Stream for UnixStream {
            fn try_clone_box(&self) -> io::Result<Box<dyn Stream>> {
                Ok(Box::new(cmux_tui_process::unix::clone_stream(self)?))
            }

            fn read_timeout(&self) -> io::Result<Option<Duration>> {
                UnixStream::read_timeout(self)
            }

            fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
                UnixStream::set_read_timeout(self, timeout)
            }

            fn write_timeout(&self) -> io::Result<Option<Duration>> {
                UnixStream::write_timeout(self)
            }

            fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
                UnixStream::set_write_timeout(self, timeout)
            }

            fn shutdown(&self, how: std::net::Shutdown) -> io::Result<()> {
                UnixStream::shutdown(self, how)
            }

            fn peer_process_id(&self) -> io::Result<Option<u32>> {
                peer_process_id(self)
            }
        }

        #[cfg(target_os = "macos")]
        fn peer_process_id(stream: &UnixStream) -> io::Result<Option<u32>> {
            use std::mem::size_of;
            use std::os::fd::AsRawFd;

            let mut pid: libc::pid_t = 0;
            let mut length = size_of::<libc::pid_t>() as libc::socklen_t;
            let result = unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_LOCAL,
                    libc::LOCAL_PEERPID,
                    (&raw mut pid).cast(),
                    &raw mut length,
                )
            };
            if result != 0 {
                return Err(io::Error::last_os_error());
            }
            if length as usize != size_of::<libc::pid_t>() {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid peer process id"));
            }
            u32::try_from(pid)
                .map(Some)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid peer process id"))
        }

        #[cfg(target_os = "linux")]
        fn peer_process_id(stream: &UnixStream) -> io::Result<Option<u32>> {
            use std::mem::{size_of, zeroed};
            use std::os::fd::AsRawFd;

            let mut credentials = unsafe { zeroed::<libc::ucred>() };
            let mut length = size_of::<libc::ucred>() as libc::socklen_t;
            let result = unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_PEERCRED,
                    (&raw mut credentials).cast(),
                    &raw mut length,
                )
            };
            if result != 0 {
                return Err(io::Error::last_os_error());
            }
            if length as usize != size_of::<libc::ucred>() {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid peer credentials"));
            }
            u32::try_from(credentials.pid)
                .map(Some)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "invalid peer process id"))
        }

        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        fn peer_process_id(_stream: &UnixStream) -> io::Result<Option<u32>> {
            Ok(None)
        }
    }

    #[cfg(windows)]
    mod imp {
        use std::io;
        use std::mem::{offset_of, size_of};
        use std::os::windows::io::{
            AsRawSocket, FromRawSocket, IntoRawSocket, OwnedSocket, RawSocket,
        };
        use std::path::Path;
        use std::sync::OnceLock;
        use std::time::{Duration, Instant};

        use super::Stream;
        use uds_windows::{UnixListener, UnixStream};
        use windows_sys::Win32::Networking::WinSock::{
            AF_UNIX, FIONBIO, INVALID_SOCKET, POLLNVAL, POLLWRNORM, SO_ERROR, SOCK_STREAM,
            SOCKADDR, SOCKADDR_UN, SOCKET, SOCKET_ERROR, SOL_SOCKET, WSA_FLAG_NO_HANDLE_INHERIT,
            WSA_FLAG_OVERLAPPED, WSADATA, WSAEALREADY, WSAEINPROGRESS, WSAEINTR, WSAEWOULDBLOCK,
            WSAGetLastError, WSAPOLLFD, WSAPoll, WSASocketW, WSAStartup,
            connect as winsock_connect, getsockopt, ioctlsocket,
        };

        pub(super) struct Listener {
            inner: UnixListener,
        }

        pub(super) fn listen(path: &Path) -> io::Result<Listener> {
            UnixListener::bind(path).map(|inner| Listener { inner })
        }

        pub(super) fn connect(path: &Path) -> io::Result<Box<dyn Stream>> {
            Ok(Box::new(UnixStream::connect(path)?))
        }

        pub(super) fn connect_until(path: &Path, deadline: Instant) -> io::Result<Box<dyn Stream>> {
            ensure_connect_time_remaining(deadline)?;
            initialize_winsock()?;
            let (address, address_len) = unix_socket_address(path)?;
            // SAFETY: WSASocketW receives no borrowed protocol descriptor and
            // returns a new socket handle on success.
            let socket = unsafe {
                WSASocketW(
                    AF_UNIX as i32,
                    SOCK_STREAM,
                    0,
                    std::ptr::null(),
                    0,
                    WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT,
                )
            };
            if socket == INVALID_SOCKET {
                return Err(last_winsock_error());
            }
            // SAFETY: socket is a fresh successful WSASocketW result and this
            // OwnedSocket takes its sole ownership.
            let socket = unsafe { OwnedSocket::from_raw_socket(socket as RawSocket) };
            let socket_handle = winsock_handle(&socket)?;
            let mut nonblocking = 1;
            // SAFETY: socket is valid and nonblocking points to a writable
            // u32 for the duration of the call.
            if unsafe { ioctlsocket(socket_handle, FIONBIO, &raw mut nonblocking) } == SOCKET_ERROR
            {
                return Err(last_winsock_error());
            }
            // SAFETY: address is an initialized SOCKADDR_UN with its exact
            // Winsock-visible length.
            let connected = unsafe {
                winsock_connect(socket_handle, (&raw const address).cast::<SOCKADDR>(), address_len)
            };
            if connected == SOCKET_ERROR {
                let error = last_winsock_error();
                let code = error.raw_os_error();
                let pending =
                    [Some(WSAEALREADY), Some(WSAEINPROGRESS), Some(WSAEINTR), Some(WSAEWOULDBLOCK)]
                        .contains(&code);
                if !pending {
                    return Err(error);
                }
                wait_for_connect(socket_handle, deadline)?;
            }
            nonblocking = 0;
            // SAFETY: socket remains valid and nonblocking points to a
            // writable u32 for the duration of the call.
            if unsafe { ioctlsocket(socket_handle, FIONBIO, &raw mut nonblocking) } == SOCKET_ERROR
            {
                return Err(last_winsock_error());
            }
            let raw = socket.into_raw_socket();
            // SAFETY: ownership was transferred out of OwnedSocket exactly
            // once and UnixStream accepts that same Winsock socket handle.
            Ok(Box::new(unsafe { UnixStream::from_raw_socket(raw) }))
        }

        fn winsock_handle(socket: &OwnedSocket) -> io::Result<SOCKET> {
            SOCKET::try_from(socket.as_raw_socket()).map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "transport socket handle does not fit the Winsock ABI",
                )
            })
        }

        fn initialize_winsock() -> io::Result<()> {
            static STARTUP: OnceLock<i32> = OnceLock::new();
            let result = *STARTUP.get_or_init(|| {
                // SAFETY: data is writable and lives for the duration of
                // WSAStartup. Version 2.2 is the Winsock API used below.
                unsafe {
                    let mut data = std::mem::zeroed::<WSADATA>();
                    WSAStartup(0x0202, &raw mut data)
                }
            });
            if result == 0 { Ok(()) } else { Err(io::Error::from_raw_os_error(result)) }
        }

        fn ensure_connect_time_remaining(deadline: Instant) -> io::Result<Duration> {
            deadline
                .checked_duration_since(Instant::now())
                .filter(|remaining| !remaining.is_zero())
                .ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::TimedOut,
                        "transport connection exceeded its deadline",
                    )
                })
        }

        fn wait_for_connect(socket: SOCKET, deadline: Instant) -> io::Result<()> {
            loop {
                let remaining = ensure_connect_time_remaining(deadline)?;
                let timeout_ms = remaining.as_millis().max(1).min(i32::MAX as u128) as i32;
                let mut descriptor = WSAPOLLFD { fd: socket, events: POLLWRNORM, revents: 0 };
                // SAFETY: descriptor points to one initialized WSAPOLLFD for
                // the duration of this call.
                let result = unsafe { WSAPoll(&raw mut descriptor, 1, timeout_ms) };
                if result == 0 {
                    continue;
                }
                if result == SOCKET_ERROR {
                    let error = last_winsock_error();
                    if error.raw_os_error() == Some(WSAEINTR) {
                        continue;
                    }
                    return Err(error);
                }
                if descriptor.revents & POLLNVAL != 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "transport connection socket became invalid",
                    ));
                }
                let mut socket_error = 0i32;
                let mut socket_error_len = i32::try_from(size_of::<i32>()).unwrap();
                // SAFETY: socket_error and its length describe one writable
                // i32, and socket remains a valid Winsock handle.
                if unsafe {
                    getsockopt(
                        socket,
                        SOL_SOCKET,
                        SO_ERROR,
                        (&raw mut socket_error).cast(),
                        &raw mut socket_error_len,
                    )
                } == SOCKET_ERROR
                {
                    return Err(last_winsock_error());
                }
                return if socket_error == 0 {
                    Ok(())
                } else {
                    Err(io::Error::from_raw_os_error(socket_error))
                };
            }
        }

        fn unix_socket_address(path: &Path) -> io::Result<(SOCKADDR_UN, i32)> {
            let path = path.to_str().ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "transport Unix socket path is not valid UTF-8",
                )
            })?;
            let path = path.as_bytes();
            let capacity = size_of::<SOCKADDR_UN>() - offset_of!(SOCKADDR_UN, sun_path);
            if path.is_empty() || path.len() >= capacity || path.contains(&0) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "invalid transport Unix socket path",
                ));
            }
            let mut address = SOCKADDR_UN::default();
            address.sun_family = AF_UNIX;
            for (destination, source) in address.sun_path.iter_mut().zip(path) {
                *destination = *source as i8;
            }
            let length = offset_of!(SOCKADDR_UN, sun_path) + path.len() + 1;
            Ok((
                address,
                i32::try_from(length).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "transport Unix socket path is too long",
                    )
                })?,
            ))
        }

        fn last_winsock_error() -> io::Error {
            // SAFETY: WSAGetLastError has no pointer arguments and reads the
            // calling thread's Winsock error state.
            io::Error::from_raw_os_error(unsafe { WSAGetLastError() })
        }

        impl Listener {
            pub(super) fn accept(&self) -> io::Result<Box<dyn Stream>> {
                let (stream, _) = self.inner.accept()?;
                Ok(Box::new(stream))
            }
        }

        impl Stream for UnixStream {
            fn try_clone_box(&self) -> io::Result<Box<dyn Stream>> {
                Ok(Box::new(self.try_clone()?))
            }

            fn read_timeout(&self) -> io::Result<Option<Duration>> {
                UnixStream::read_timeout(self)
            }

            fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
                UnixStream::set_read_timeout(self, timeout)
            }

            fn write_timeout(&self) -> io::Result<Option<Duration>> {
                UnixStream::write_timeout(self)
            }

            fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
                UnixStream::set_write_timeout(self, timeout)
            }

            fn shutdown(&self, how: std::net::Shutdown) -> io::Result<()> {
                UnixStream::shutdown(self, how)
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[cfg(unix)]
        static SOCKET_CREATED_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

        #[test]
        fn expired_connect_deadline_fails_before_socket_resolution() {
            let error = connect_until(
                Path::new("deadline-expired-before-address-resolution"),
                Instant::now() - Duration::from_millis(1),
            )
            .err()
            .expect("expired transport connect unexpectedly succeeded");

            assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        }

        #[cfg(unix)]
        #[test]
        fn deadline_connect_preserves_the_stream_contract() {
            let path = std::env::temp_dir().join(format!(
                "cmux-platform-connect-{}-{}.sock",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();

            let stream = connect_until(&path, Instant::now() + Duration::from_secs(1)).unwrap();
            let (_accepted, _) = listener.accept().unwrap();

            drop(stream);
            drop(listener);
            std::fs::remove_file(path).unwrap();
        }

        #[cfg(target_os = "linux")]
        #[test]
        fn deadline_connect_is_close_on_exec_at_socket_creation() {
            use std::sync::Arc;
            use std::sync::atomic::{AtomicBool, Ordering};

            let _guard = SOCKET_CREATED_TEST_LOCK.lock().unwrap();
            let path = std::env::temp_dir().join(format!(
                "cmux-platform-cloexec-{}-{}.sock",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
            let close_on_exec = Arc::new(AtomicBool::new(false));
            imp::set_socket_created_hook(Some(Arc::new({
                let close_on_exec = close_on_exec.clone();
                move |descriptor| {
                    // SAFETY: the hook receives the fresh live socket
                    // descriptor before connect_until performs any fallback.
                    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
                    close_on_exec
                        .store(flags >= 0 && flags & libc::FD_CLOEXEC != 0, Ordering::Release);
                }
            })));

            let stream = connect_until(&path, Instant::now() + Duration::from_secs(1)).unwrap();
            imp::set_socket_created_hook(None);
            let (_accepted, _) = listener.accept().unwrap();

            drop(stream);
            drop(listener);
            std::fs::remove_file(path).unwrap();
            assert!(
                close_on_exec.load(Ordering::Acquire),
                "deadline connector exposed an inheritable descriptor before setting close-on-exec"
            );
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn deadline_connect_confines_inheritable_descriptor_to_process_barrier() {
            use std::os::fd::AsRawFd as _;
            use std::sync::Arc;
            use std::sync::atomic::{AtomicBool, Ordering};

            let _guard = SOCKET_CREATED_TEST_LOCK.lock().unwrap();
            let path = std::path::PathBuf::from("/tmp").join(format!(
                "cmux-cxfb-{}-{}.sock",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
            let descriptor_was_inheritable = Arc::new(AtomicBool::new(false));
            imp::set_socket_created_hook(Some(Arc::new({
                let descriptor_was_inheritable = descriptor_was_inheritable.clone();
                move |descriptor| {
                    // SAFETY: the hook receives the fresh live socket before
                    // the process barrier is released.
                    let flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
                    descriptor_was_inheritable
                        .store(flags >= 0 && flags & libc::FD_CLOEXEC == 0, Ordering::Release);
                }
            })));

            let stream =
                connect_unix_until(&path, Instant::now() + Duration::from_secs(1)).unwrap();
            imp::set_socket_created_hook(None);
            let flags = unsafe { libc::fcntl(stream.as_raw_fd(), libc::F_GETFD) };
            let (_accepted, _) = listener.accept().unwrap();

            drop(stream);
            drop(listener);
            std::fs::remove_file(path).unwrap();
            assert!(
                descriptor_was_inheritable.load(Ordering::Acquire),
                "test did not observe the non-atomic macOS descriptor setup window"
            );
            assert!(flags >= 0 && flags & libc::FD_CLOEXEC != 0);
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn deadline_connect_excludes_concurrent_browser_process_creation() {
            use std::os::unix::fs::PermissionsExt as _;
            use std::sync::Arc;
            use std::sync::mpsc;

            let _guard = SOCKET_CREATED_TEST_LOCK.lock().unwrap();
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::path::PathBuf::from("/tmp")
                .join(format!("cmux-cxspawn-{}-{nonce}", std::process::id()));
            std::fs::create_dir(&root).unwrap();
            let socket_path = root.join("server.sock");
            let listener = std::os::unix::net::UnixListener::bind(&socket_path).unwrap();
            let marker_path = root.join("descriptor-state");
            let browser_path = root.join("browser");
            let profile_path = root.join("profile");
            let (descriptor_sender, descriptor_receiver) = mpsc::sync_channel(1);
            let (release_sender, release_receiver) = mpsc::sync_channel(1);
            let release_receiver = Arc::new(std::sync::Mutex::new(release_receiver));
            imp::set_socket_created_hook(Some(Arc::new({
                move |descriptor| {
                    descriptor_sender.send(descriptor).unwrap();
                    release_receiver
                        .lock()
                        .unwrap()
                        .recv_timeout(Duration::from_secs(5))
                        .expect("test did not release descriptor setup");
                }
            })));

            let connector = std::thread::spawn({
                move || connect_unix_until(&socket_path, Instant::now() + Duration::from_secs(5))
            });
            let descriptor = descriptor_receiver
                .recv_timeout(Duration::from_secs(5))
                .expect("connector did not expose its descriptor setup window");
            std::fs::write(
                &browser_path,
                format!(
                    "#!/bin/sh\n\
                     if [ -e /dev/fd/{descriptor} ]; then\n\
                       printf inherited > {}\n\
                     else\n\
                       printf closed > {}\n\
                     fi\n\
                     printf 'DevTools listening on ws://127.0.0.1:1/devtools/browser/test\\n' >&2\n\
                     exec /bin/sleep 30\n",
                    marker_path.display(),
                    marker_path.display()
                ),
            )
            .unwrap();
            let mut permissions = std::fs::metadata(&browser_path).unwrap().permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(&browser_path, permissions).unwrap();

            let (launch_started_sender, launch_started_receiver) = mpsc::sync_channel(1);
            let (launch_result_sender, launch_result_receiver) = mpsc::sync_channel(1);
            let launcher = std::thread::spawn(move || {
                launch_started_sender.send(()).unwrap();
                let result =
                    cmux_tui_cdp::Chrome::launch_with(&cmux_tui_cdp::ChromeLaunchOptions {
                        binary: browser_path,
                        mode: cmux_tui_cdp::BrowserMode::Headless,
                        user_data_dir: Some(profile_path),
                        ephemeral: false,
                    })
                    .map(drop)
                    .map_err(|error| error.to_string());
                launch_result_sender.send(result).unwrap();
            });
            launch_started_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
            let launch_result_before_close_on_exec =
                launch_result_receiver.recv_timeout(Duration::from_millis(500)).ok();
            let launched_before_close_on_exec = launch_result_before_close_on_exec.is_some();

            release_sender.send(()).unwrap();
            let stream = connector.join().unwrap().unwrap();
            imp::set_socket_created_hook(None);
            let (_accepted, _) = listener.accept().unwrap();
            let launch_result = launch_result_before_close_on_exec.unwrap_or_else(|| {
                launch_result_receiver
                    .recv_timeout(Duration::from_secs(5))
                    .expect("browser process did not launch after descriptor setup completed")
            });
            launcher.join().unwrap();
            let descriptor_state = std::fs::read_to_string(&marker_path).unwrap();

            drop(stream);
            drop(listener);
            std::fs::remove_dir_all(&root).unwrap();
            launch_result.unwrap();
            assert!(
                !launched_before_close_on_exec,
                "browser process launched while the connector descriptor was still inheritable"
            );
            assert_eq!(
                descriptor_state, "closed",
                "browser process inherited the connector descriptor"
            );
        }

        #[cfg(target_os = "macos")]
        #[test]
        fn transport_listener_creation_waits_for_the_process_barrier() {
            use std::sync::mpsc;

            let _serial = SOCKET_CREATED_TEST_LOCK.lock().unwrap();
            let path = std::path::PathBuf::from("/tmp").join(format!(
                "cmux-listen-barrier-{}-{}.sock",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let process_barrier = cmux_tui_process::ProcessCreationGuard::acquire();
            let (result_sender, result_receiver) = mpsc::sync_channel(1);
            let creator = std::thread::spawn({
                let path = path.clone();
                move || result_sender.send(listen(&path)).unwrap()
            });

            assert!(
                result_receiver.recv_timeout(Duration::from_millis(250)).is_err(),
                "Unix listener creation bypassed the process-wide descriptor barrier"
            );
            drop(process_barrier);
            let listener = result_receiver.recv_timeout(Duration::from_secs(2)).unwrap().unwrap();
            creator.join().unwrap();

            drop(listener);
            std::fs::remove_file(path).unwrap();
        }

        #[cfg(target_os = "linux")]
        #[test]
        fn deadline_connect_times_out_while_listener_backlog_is_saturated() {
            use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

            let path = std::env::temp_dir().join(format!(
                "cmux-platform-backlog-{}-{}.sock",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            let (address, address_len) = imp::unix_socket_address(&path).unwrap();
            // SAFETY: socket has no pointer arguments and returns a new owned
            // descriptor on success.
            let listener =
                unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
            assert!(listener >= 0, "failed to create the test listener");
            // SAFETY: listener is a fresh successful socket result and this
            // OwnedFd takes its sole ownership.
            let listener = unsafe { OwnedFd::from_raw_fd(listener) };
            // SAFETY: address is initialized for this exact filesystem path
            // and listener owns a valid AF_UNIX descriptor.
            let result = unsafe {
                libc::bind(
                    listener.as_raw_fd(),
                    (&raw const address).cast::<libc::sockaddr>(),
                    address_len,
                )
            };
            assert_eq!(result, 0, "failed to bind the test listener");
            // SAFETY: listener remains a valid bound AF_UNIX descriptor.
            let result = unsafe { libc::listen(listener.as_raw_fd(), 0) };
            assert_eq!(result, 0, "failed to create a zero-backlog test listener");
            let mut queued = Vec::new();
            let mut timeout_elapsed = None;
            for _ in 0..32 {
                let started = Instant::now();
                match connect_until(&path, started + Duration::from_millis(75)) {
                    Ok(stream) => queued.push(stream),
                    Err(error) => {
                        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
                        timeout_elapsed = Some(started.elapsed());
                        break;
                    }
                }
            }
            let elapsed =
                timeout_elapsed.expect("could not saturate the listener backlog with 32 clients");
            assert!(
                elapsed < Duration::from_secs(1),
                "saturated listener connect exceeded its deadline bound: {elapsed:?}"
            );
            drop(queued);
            drop(listener);
            std::fs::remove_file(path).unwrap();
        }
    }
}

/// Runtime socket/pidfile directory for the current user.
pub fn runtime_dir() -> PathBuf {
    runtime_base_dir().join(format!("cmux-tui-{}", user_id_component()))
}

/// Short, user-private runtime directory used when the preferred runtime
/// directory would make a Unix-domain socket path too long for `sockaddr_un`.
///
/// Keep this path stable across frontends: clients must derive the same
/// fallback without first connecting to the server.
#[cfg(unix)]
pub fn fallback_runtime_dir() -> PathBuf {
    PathBuf::from("/tmp").join(format!("cmux-tui-{}", user_id_component()))
}

/// Default root for durable workspace/session state. Runtime sockets stay in
/// the short-lived runtime directory; canonical identities and mutation
/// ledgers live here across daemon and machine reboots.
pub fn workspace_state_dir() -> Option<PathBuf> {
    if let Some(path) = env_path("CMUX_TUI_STATE_DIR") {
        return Some(path);
    }
    #[cfg(target_os = "macos")]
    {
        home_dir().map(|home| {
            home.join("Library").join("Application Support").join("cmux-tui").join("sessions")
        })
    }
    #[cfg(target_os = "linux")]
    {
        env_path("XDG_STATE_HOME").map(|state| state.join("cmux-tui").join("sessions")).or_else(
            || {
                home_dir()
                    .map(|home| home.join(".local").join("state").join("cmux-tui").join("sessions"))
            },
        )
    }
    #[cfg(windows)]
    {
        return env_path("LOCALAPPDATA").map(|dir| dir.join("cmux-tui").join("sessions"));
    }
    #[cfg(all(not(target_os = "macos"), not(target_os = "linux"), not(windows)))]
    {
        env_path("XDG_STATE_HOME").map(|state| state.join("cmux-tui").join("sessions")).or_else(
            || {
                home_dir()
                    .map(|home| home.join(".local").join("state").join("cmux-tui").join("sessions"))
            },
        )
    }
}

/// User config file path, honoring explicit env overrides before the default
/// cmux config directory. `cmux-tui.json` is preferred, with `mux.json`
/// retained as a compatibility fallback for existing installs.
pub fn config_path() -> Option<PathBuf> {
    if let Some(path) = env_path("CMUX_TUI_CONFIG").or_else(|| env_path("CMUX_MUX_CONFIG")) {
        return Some(path);
    }
    config_dir().map(preferred_config_path)
}

#[cfg(not(windows))]
fn config_dir() -> Option<PathBuf> {
    env_path("XDG_CONFIG_HOME")
        .map(|config_home| config_home.join("cmux"))
        .or_else(|| home_dir().map(|home| home.join(".config").join("cmux")))
}

#[cfg(windows)]
fn config_dir() -> Option<PathBuf> {
    env_path("APPDATA").map(|appdata| appdata.join("cmux"))
}

fn preferred_config_path(dir: PathBuf) -> PathBuf {
    let preferred = dir.join("cmux-tui.json");
    if preferred.exists() {
        return preferred;
    }
    let legacy = dir.join("mux.json");
    if legacy.exists() { legacy } else { preferred }
}

/// Default interactive shell for spawned PTY surfaces.
#[cfg(not(windows))]
pub fn default_shell() -> String {
    if let Some(shell) = env_string("SHELL") {
        return shell;
    }

    if Path::new("/bin/bash").is_file() { "/bin/bash".to_string() } else { "/bin/sh".to_string() }
}

/// Default interactive shell for spawned PTY surfaces.
#[cfg(windows)]
pub fn default_shell() -> String {
    find_on_path(&["pwsh.exe", "powershell.exe", "cmd.exe"])
        .map(|path| path.display().to_string())
        .unwrap_or_else(|| "cmd.exe".to_string())
}

/// Candidate Chrome/Chromium-family binaries in platform discovery order.
pub fn chrome_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    #[cfg(target_os = "macos")]
    {
        push_unique(
            &mut candidates,
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome".into(),
        );
        push_unique(&mut candidates, "/Applications/Chromium.app/Contents/MacOS/Chromium".into());
        push_unique(
            &mut candidates,
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser".into(),
        );
        push_unique(
            &mut candidates,
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge".into(),
        );
        push_path_candidates(
            &mut candidates,
            &[
                "google-chrome",
                "google-chrome-stable",
                "chromium",
                "chromium-browser",
                "brave-browser",
                "microsoft-edge",
            ],
        );
    }

    #[cfg(target_os = "linux")]
    {
        push_path_candidates(
            &mut candidates,
            &["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"],
        );
        for path in [
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/snap/bin/chromium",
            "/opt/google/chrome/chrome",
            "/opt/chromium.org/chromium/chromium",
        ] {
            push_unique(&mut candidates, path.into());
        }
    }

    #[cfg(windows)]
    {
        push_path_candidates(
            &mut candidates,
            &["chrome.exe", "google-chrome.exe", "chromium.exe", "msedge.exe", "brave.exe"],
        );
        for base in ["PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA"] {
            if let Some(dir) = env_path(base) {
                for path in [
                    dir.join("Google").join("Chrome").join("Application").join("chrome.exe"),
                    dir.join("Chromium").join("Application").join("chrome.exe"),
                    dir.join("BraveSoftware")
                        .join("Brave-Browser")
                        .join("Application")
                        .join("brave.exe"),
                    dir.join("Microsoft").join("Edge").join("Application").join("msedge.exe"),
                ] {
                    push_unique(&mut candidates, path);
                }
            }
        }
    }

    #[cfg(all(unix, not(any(target_os = "macos", target_os = "linux"))))]
    {
        push_path_candidates(
            &mut candidates,
            &["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"],
        );
    }

    candidates
}

/// Candidate Ghostty config files used to seed selection colors.
pub fn ghostty_config_paths() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(config_home) = env_path("XDG_CONFIG_HOME") {
        push_unique(&mut candidates, config_home.join("ghostty").join("config"));
    }
    if let Some(home) = home_dir() {
        push_unique(&mut candidates, home.join(".config").join("ghostty").join("config"));
        #[cfg(target_os = "macos")]
        push_unique(
            &mut candidates,
            home.join("Library")
                .join("Application Support")
                .join("com.mitchellh.ghostty")
                .join("config"),
        );
    }
    candidates
}

/// A Ghostty config resolver and the resources that must accompany it.
///
/// The executable and resource directory are kept together because a helper
/// embedded in another app bundle cannot infer `Contents/Resources/ghostty`
/// from its own location the way Ghostty.app can.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GhosttyInstallation {
    pub binary: PathBuf,
    pub resources_dir: Option<PathBuf>,
}

/// Candidate Ghostty installations, in the order cmux-tui should probe them.
///
/// An explicit `GHOSTTY_BIN` remains authoritative. Otherwise, prefer the
/// standalone CLI helper and resources shipped beside this exact cmux-tui
/// executable, then the intact pinned dogfood app, before considering a PATH
/// or system Ghostty. The package-local helper must be built with Ghostty's
/// `cli-helper` target; copying a macOS app executable without its Frameworks
/// directory is not sufficient. Failed candidates are skipped by the config
/// resolver. This keeps a packaged cmux frontend from silently resolving its
/// theme with an unrelated Ghostty installation.
pub fn ghostty_installations() -> Vec<GhosttyInstallation> {
    let current_exe = std::env::current_exe().ok();
    let explicit_binary = env_path("GHOSTTY_BIN");
    let explicit_resources = env_path("GHOSTTY_RESOURCES_DIR");
    let home = home_dir();
    let path_binary = find_on_path(&["ghostty"]);
    let mut candidates = ghostty_installation_candidates(
        explicit_binary,
        explicit_resources,
        current_exe.as_deref(),
        home.as_deref(),
        path_binary,
    );
    candidates.retain(|candidate| is_executable_file(&candidate.binary));
    for candidate in &mut candidates {
        candidate.resources_dir =
            candidate.resources_dir.take().filter(|path| path.is_dir()).or_else(|| {
                candidate
                    .binary
                    .canonicalize()
                    .ok()
                    .and_then(|path| ghostty_resources_for_binary(&path))
                    .filter(|path| path.is_dir())
            });
    }
    candidates
}

/// Compatibility view for callers that only need executable paths.
pub fn ghostty_binary_paths() -> Vec<PathBuf> {
    ghostty_installations().into_iter().map(|candidate| candidate.binary).collect()
}

/// Theme directories in Ghostty's resolution order.
///
/// A user-supplied theme overrides a bundled one with the same name. Include
/// cmux's bundled Ghostty resources as well so the headless fallback works
/// when cmux is installed without the standalone Ghostty app.
pub fn ghostty_theme_dirs() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(config_home) = env_path("XDG_CONFIG_HOME") {
        push_unique(&mut candidates, config_home.join("ghostty").join("themes"));
    } else if let Some(home) = home_dir() {
        push_unique(&mut candidates, home.join(".config").join("ghostty").join("themes"));
    }
    let current_exe = std::env::current_exe().ok();
    for installation in ghostty_installation_candidates(
        env_path("GHOSTTY_BIN"),
        env_path("GHOSTTY_RESOURCES_DIR"),
        current_exe.as_deref(),
        home_dir().as_deref(),
        find_on_path(&["ghostty"]),
    ) {
        if let Some(path) = installation.resources_dir {
            push_unique(&mut candidates, path.join("themes"));
        }
    }
    candidates
}

fn ghostty_installation_candidates(
    explicit_binary: Option<PathBuf>,
    explicit_resources: Option<PathBuf>,
    current_exe: Option<&Path>,
    home: Option<&Path>,
    path_binary: Option<PathBuf>,
) -> Vec<GhosttyInstallation> {
    let mut candidates = Vec::new();

    if let Some(binary) = explicit_binary.as_ref() {
        push_unique_installation(
            &mut candidates,
            binary.clone(),
            explicit_resources.clone().or_else(|| ghostty_resources_for_binary(binary)),
        );
    }

    if let Some(current_exe) = current_exe {
        for candidate in packaged_ghostty_installations(current_exe) {
            push_unique_installation(&mut candidates, candidate.binary, candidate.resources_dir);
        }
    }

    if let Some(home) = home {
        push_app_installation(
            &mut candidates,
            &home.join("Applications").join("Ghostty-cmux-pinned.app"),
        );
    }
    push_app_installation(&mut candidates, Path::new("/Applications/Ghostty-cmux-pinned.app"));

    // `GHOSTTY_RESOURCES_DIR` is commonly inherited from the terminal that
    // launched cmux, so it is a resource hint rather than proof that a helper
    // matches this build. Only use a binary inferred from it after package-local
    // and explicitly pinned installations.
    if let Some(resources) = explicit_resources.as_ref() {
        for binary in ghostty_binaries_for_resources(resources) {
            push_unique_installation(&mut candidates, binary, Some(resources.clone()));
        }
    }
    push_unique_installation(
        &mut candidates,
        PathBuf::from("/Applications/cmux.app/Contents/Resources/bin/ghostty"),
        Some(PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty")),
    );

    if let Some(binary) = path_binary {
        push_unique_installation(
            &mut candidates,
            binary.clone(),
            ghostty_resources_for_binary(&binary),
        );
    }
    push_app_installation(&mut candidates, Path::new("/Applications/Ghostty.app"));
    candidates
}

fn packaged_ghostty_installations(current_exe: &Path) -> Vec<GhosttyInstallation> {
    let mut candidates = Vec::new();
    let Some(executable_dir) = current_exe.parent() else { return candidates };

    // macOS app bundle: cmux-tui is installed in Contents/Helpers while a
    // standalone Ghostty `cli-helper` build and resources live in
    // Contents/Resources. Do not copy Ghostty.app's MacOS executable here: it
    // has app-relative framework dependencies that are absent in this layout.
    if executable_dir.file_name().is_some_and(|name| name == "Helpers" || name == "MacOS")
        && let Some(contents) = executable_dir.parent()
        && contents.file_name().is_some_and(|name| name == "Contents")
    {
        let resources = contents.join("Resources");
        push_unique_installation(
            &mut candidates,
            resources.join("bin").join("ghostty"),
            Some(resources.join("ghostty")),
        );
    }

    // Flat release artifact: cmux-tui, bin/ghostty, and ghostty/ share a root.
    push_unique_installation(
        &mut candidates,
        executable_dir.join("bin").join("ghostty"),
        Some(executable_dir.join("ghostty")),
    );

    // Conventional prefix: bin/cmux-tui + bin/ghostty + share/ghostty.
    if executable_dir.file_name().is_some_and(|name| name == "bin")
        && let Some(prefix) = executable_dir.parent()
    {
        push_unique_installation(
            &mut candidates,
            executable_dir.join("ghostty"),
            Some(prefix.join("share").join("ghostty")),
        );
    }
    candidates
}

fn ghostty_binaries_for_resources(resources: &Path) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    let Some(parent) = resources.parent() else { return candidates };
    if parent.file_name().is_some_and(|name| name == "Resources") {
        push_unique(&mut candidates, parent.join("bin").join("ghostty"));
        if let Some(contents) = parent.parent()
            && contents.file_name().is_some_and(|name| name == "Contents")
        {
            push_unique(&mut candidates, contents.join("MacOS").join("ghostty"));
        }
    } else if parent.file_name().is_some_and(|name| name == "share") {
        if let Some(prefix) = parent.parent() {
            push_unique(&mut candidates, prefix.join("bin").join("ghostty"));
        }
    } else {
        push_unique(&mut candidates, parent.join("bin").join("ghostty"));
    }
    candidates
}

fn ghostty_resources_for_binary(binary: &Path) -> Option<PathBuf> {
    let binary_dir = binary.parent()?;
    if binary_dir.file_name().is_some_and(|name| name == "MacOS") {
        let contents = binary_dir.parent()?;
        if contents.file_name().is_some_and(|name| name == "Contents") {
            return Some(contents.join("Resources").join("ghostty"));
        }
    }
    if binary_dir.file_name().is_some_and(|name| name == "bin") {
        let parent = binary_dir.parent()?;
        if parent.file_name().is_some_and(|name| name == "Resources") {
            return Some(parent.join("ghostty"));
        }
        return Some(parent.join("share").join("ghostty"));
    }
    None
}

fn push_app_installation(candidates: &mut Vec<GhosttyInstallation>, app: &Path) {
    push_unique_installation(
        candidates,
        app.join("Contents").join("MacOS").join("ghostty"),
        Some(app.join("Contents").join("Resources").join("ghostty")),
    );
}

fn push_unique_installation(
    candidates: &mut Vec<GhosttyInstallation>,
    binary: PathBuf,
    resources_dir: Option<PathBuf>,
) {
    if let Some(existing) = candidates.iter_mut().find(|candidate| candidate.binary == binary) {
        if existing.resources_dir.is_none() {
            existing.resources_dir = resources_dir;
        }
        return;
    }
    candidates.push(GhosttyInstallation { binary, resources_dir });
}

/// Persistent profile directory for launched Chrome/Chromium sessions.
pub fn chrome_user_data_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        home_dir().map(|home| {
            home.join("Library").join("Application Support").join("cmux-tui").join("chrome-profile")
        })
    }

    #[cfg(target_os = "linux")]
    {
        env_path("XDG_DATA_HOME")
            .map(|data_home| data_home.join("cmux-tui").join("chrome-profile"))
            .or_else(|| {
                home_dir().map(|home| {
                    home.join(".local").join("share").join("cmux-tui").join("chrome-profile")
                })
            })
    }

    #[cfg(windows)]
    {
        env_path("LOCALAPPDATA").map(|dir| dir.join("cmux-tui").join("chrome-profile"))
    }

    #[cfg(all(not(target_os = "macos"), not(target_os = "linux"), not(windows)))]
    {
        env_path("XDG_DATA_HOME").map(|dir| dir.join("cmux-tui").join("chrome-profile")).or_else(
            || {
                home_dir().map(|home| {
                    home.join(".local").join("share").join("cmux-tui").join("chrome-profile")
                })
            },
        )
    }
}

pub fn restrict_directory(path: &Path) -> std::io::Result<()> {
    restrict_permissions(path, 0o700)
}

pub fn restrict_file(path: &Path) -> std::io::Result<()> {
    restrict_permissions(path, 0o600)
}

pub fn is_executable_file(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else { return false };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

#[cfg(not(windows))]
fn runtime_base_dir() -> PathBuf {
    env_path("XDG_RUNTIME_DIR")
        .or_else(|| env_path("TMPDIR"))
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

#[cfg(windows)]
fn runtime_base_dir() -> PathBuf {
    env_path("TEMP").or_else(|| env_path("TMP")).unwrap_or_else(std::env::temp_dir)
}

#[cfg(not(windows))]
pub fn home_dir() -> Option<PathBuf> {
    env_path("HOME")
}

#[cfg(windows)]
pub fn home_dir() -> Option<PathBuf> {
    env_path("USERPROFILE").or_else(|| {
        let drive = std::env::var_os("HOMEDRIVE")?;
        let path = std::env::var_os("HOMEPATH")?;
        let mut home = PathBuf::from(drive);
        home.push(path);
        Some(home)
    })
}

fn env_path(name: &str) -> Option<PathBuf> {
    let value = std::env::var_os(name)?;
    (!value.is_empty()).then(|| PathBuf::from(value))
}

#[cfg(not(windows))]
fn env_string(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.trim().is_empty())
}

#[cfg(unix)]
fn user_id_component() -> String {
    unsafe { libc::getuid() }.to_string()
}

#[cfg(windows)]
fn user_id_component() -> String {
    std::env::var("USERNAME").unwrap_or_else(|_| "user".to_string())
}

fn push_path_candidates(candidates: &mut Vec<PathBuf>, names: &[&str]) {
    for name in names {
        if let Some(candidate) = find_on_path(&[*name]) {
            push_unique(candidates, candidate);
        }
    }
}

fn find_on_path(names: &[&str]) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for name in names {
        for dir in std::env::split_paths(&path) {
            let candidate = dir.join(name);
            if is_executable_file(&candidate) {
                return Some(candidate);
            }
        }
    }
    None
}

fn push_unique(candidates: &mut Vec<PathBuf>, path: PathBuf) {
    if !candidates.iter().any(|candidate| candidate == &path) {
        candidates.push(path);
    }
}

#[cfg(unix)]
fn restrict_permissions(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
fn restrict_permissions(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(any(target_os = "macos", target_os = "linux"))]
    #[test]
    fn unix_transport_reports_the_kernel_peer_process() {
        use std::os::unix::net::UnixStream;

        use transport::Stream as _;

        let (client, server) = UnixStream::pair().unwrap();

        assert_eq!(client.peer_process_id().unwrap(), Some(std::process::id()));
        assert_eq!(server.peer_process_id().unwrap(), Some(std::process::id()));
    }

    fn position(candidates: &[GhosttyInstallation], expected: impl AsRef<Path>) -> usize {
        let expected = expected.as_ref();
        candidates
            .iter()
            .position(|candidate| candidate.binary == expected)
            .unwrap_or_else(|| panic!("missing Ghostty candidate {}", expected.display()))
    }

    #[test]
    fn packaged_and_pinned_ghostty_precede_path_and_system_installs() {
        let browser = Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui");
        let home = Path::new("/Users/tester");
        let path_binary = PathBuf::from("/opt/homebrew/bin/ghostty");
        let candidates = ghostty_installation_candidates(
            None,
            None,
            Some(browser),
            Some(home),
            Some(path_binary.clone()),
        );

        let packaged = Path::new("/tmp/cmux-browser.app/Contents/Resources/bin/ghostty");
        let pinned = home
            .join("Applications")
            .join("Ghostty-cmux-pinned.app")
            .join("Contents")
            .join("MacOS")
            .join("ghostty");
        let system = Path::new("/Applications/Ghostty.app/Contents/MacOS/ghostty");
        assert!(position(&candidates, packaged) < position(&candidates, &pinned));
        assert!(position(&candidates, &pinned) < position(&candidates, &path_binary));
        assert!(position(&candidates, &path_binary) < position(&candidates, system));

        let packaged_installation = &candidates[position(&candidates, packaged)];
        assert_eq!(
            packaged_installation.resources_dir.as_deref(),
            Some(Path::new("/tmp/cmux-browser.app/Contents/Resources/ghostty"))
        );
    }

    #[test]
    fn explicit_ghostty_installation_remains_authoritative() {
        let explicit = PathBuf::from("/custom/pinned/bin/ghostty");
        let resources = PathBuf::from("/custom/pinned/share/ghostty");
        let candidates = ghostty_installation_candidates(
            Some(explicit.clone()),
            Some(resources.clone()),
            Some(Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui")),
            Some(Path::new("/Users/tester")),
            Some(PathBuf::from("/usr/local/bin/ghostty")),
        );

        assert_eq!(candidates[0].binary, explicit);
        assert_eq!(candidates[0].resources_dir, Some(resources));
    }

    #[test]
    fn inherited_resource_hint_does_not_outrank_pinned_installation() {
        let home = Path::new("/Users/tester");
        let inherited_resources =
            PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty");
        let candidates = ghostty_installation_candidates(
            None,
            Some(inherited_resources),
            Some(Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui")),
            Some(home),
            Some(PathBuf::from("/usr/local/bin/ghostty")),
        );
        let pinned = home
            .join("Applications")
            .join("Ghostty-cmux-pinned.app")
            .join("Contents")
            .join("MacOS")
            .join("ghostty");
        let inherited_helper = Path::new("/Applications/cmux.app/Contents/Resources/bin/ghostty");

        assert!(position(&candidates, &pinned) < position(&candidates, inherited_helper));
    }

    #[test]
    fn packaged_theme_resources_precede_legacy_ghostty_resources() {
        let browser = Path::new("/tmp/cmux-browser.app/Contents/Helpers/cmux-tui");
        let home = Path::new("/Users/tester");
        let path_binary = PathBuf::from("/opt/homebrew/bin/ghostty");
        let inherited = PathBuf::from("/Applications/cmux.app/Contents/Resources/ghostty");
        let candidates = ghostty_installation_candidates(
            None,
            Some(inherited.clone()),
            Some(browser),
            Some(home),
            Some(path_binary),
        )
        .into_iter()
        .filter_map(|candidate| candidate.resources_dir)
        .collect::<Vec<_>>();

        let packaged = Path::new("/tmp/cmux-browser.app/Contents/Resources/ghostty");
        let pinned = Path::new(
            "/Users/tester/Applications/Ghostty-cmux-pinned.app/Contents/Resources/ghostty",
        );
        let global_pinned =
            Path::new("/Applications/Ghostty-cmux-pinned.app/Contents/Resources/ghostty");
        let system = Path::new("/Applications/Ghostty.app/Contents/Resources/ghostty");
        let position = |expected: &Path| {
            candidates
                .iter()
                .position(|candidate| candidate == expected)
                .unwrap_or_else(|| panic!("missing Ghostty resources {}", expected.display()))
        };
        assert!(position(packaged) < position(pinned));
        assert!(position(pinned) < position(&inherited));
        assert!(position(global_pinned) < position(&inherited));
        assert!(position(pinned) < position(system));
    }

    #[test]
    fn derives_resource_paths_for_app_bundle_and_packaged_helper() {
        assert_eq!(
            ghostty_resources_for_binary(Path::new(
                "/Applications/Ghostty.app/Contents/MacOS/ghostty"
            )),
            Some(PathBuf::from("/Applications/Ghostty.app/Contents/Resources/ghostty"))
        );
        assert_eq!(
            ghostty_resources_for_binary(Path::new(
                "/Applications/cmux-browser.app/Contents/Resources/bin/ghostty"
            )),
            Some(PathBuf::from("/Applications/cmux-browser.app/Contents/Resources/ghostty"))
        );
    }
}
