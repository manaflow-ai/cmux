//! Client side of the cmux PTY keeper.
//!
//! A keeper is a tiny per-terminal process that owns the PTY and the child
//! and never changes once started (see `PROTOCOL.md`). Hosts, the mux, and
//! renderers restart and upgrade freely: a new host spawns nothing, it
//! connects to the existing keeper and gets the PTY back.
//!
//! This library is the updatable half. It may grow; the keeper binary and
//! the v1 frames must not.

use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};

pub mod protocol;
#[cfg(windows)]
#[doc(hidden)]
pub mod win_io;

use protocol::Frame;
pub use protocol::Size;

/// A child's raw platform exit status from an `EXIT` frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ExitStatus(pub u32);

impl ExitStatus {
    /// The exit code when the child exited normally.
    pub fn code(&self) -> Option<i32> {
        #[cfg(unix)]
        {
            let raw = self.0 as libc::c_int;
            libc::WIFEXITED(raw).then_some(libc::WEXITSTATUS(raw))
        }
        #[cfg(windows)]
        {
            Some(self.0 as i32)
        }
    }

    /// The terminating signal on Unix.
    pub fn signal(&self) -> Option<i32> {
        #[cfg(unix)]
        {
            let raw = self.0 as libc::c_int;
            libc::WIFSIGNALED(raw).then_some(libc::WTERMSIG(raw))
        }
        #[cfg(windows)]
        {
            None
        }
    }
}

/// Starts a keeper and waits for its readiness line. Returns the
/// long-lived keeper pid.
///
/// `configure` sets the child's environment and working directory, which
/// the keeper passes through unchanged. It may run twice on Windows when
/// the caller's job forbids breakaway.
pub fn spawn<I, S>(
    keeper: &Path,
    endpoint: &str,
    cols: u16,
    rows: u16,
    program: impl AsRef<OsStr>,
    args: I,
    configure: impl Fn(&mut Command),
) -> io::Result<u32>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let args: Vec<_> = args.into_iter().map(|arg| arg.as_ref().to_owned()).collect();
    let build = || {
        let mut command = Command::new(keeper);
        command
            .arg(endpoint)
            .arg(cols.to_string())
            .arg(rows.to_string())
            .arg("--")
            .arg(program.as_ref())
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        configure(&mut command);
        command
    };
    let mut child = spawn_detached(build)?;
    let stdout = child.stdout.take().expect("stdout is piped");
    let mut line = String::new();
    BufReader::new(stdout).read_line(&mut line)?;
    // On Unix the started process exits right after it forks the keeper.
    #[cfg(unix)]
    child.wait()?;
    let line = line.trim_end();
    if let Some(pid) = line.strip_prefix("ready ") {
        return pid.parse().map_err(|_| {
            io::Error::new(io::ErrorKind::InvalidData, format!("keeper said {line:?}"))
        });
    }
    let message = line.strip_prefix("error ").unwrap_or("exited without a readiness line");
    Err(io::Error::other(format!("keeper failed to start: {message}")))
}

#[cfg(unix)]
fn spawn_detached(build: impl Fn() -> Command) -> io::Result<std::process::Child> {
    build().spawn()
}

#[cfg(windows)]
fn spawn_detached(build: impl Fn() -> Command) -> io::Result<std::process::Child> {
    use std::os::windows::process::CommandExt;
    use windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED;
    use windows_sys::Win32::System::Threading::{
        CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, DETACHED_PROCESS,
    };
    let flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;
    match build().creation_flags(flags | CREATE_BREAKAWAY_FROM_JOB).spawn() {
        Err(error) if error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) => {
            build().creation_flags(flags).spawn()
        }
        result => result,
    }
}

/// The PTY streams a keeper hands to a client.
pub struct PtyIo {
    /// Terminal output from the child.
    pub reader: File,
    /// Terminal input to the child.
    pub writer: File,
}

/// A report from the keeper.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// The terminal now has `size`; `generation` counts applied resizes.
    Size {
        size: Size,
        generation: u64,
    },
    Exit(ExitStatus),
}

/// One connection to a running keeper.
pub struct Connection {
    child_pid: u32,
    version: u16,
    io: Option<PtyIo>,
    size: Size,
    generation: u64,
    exit: Option<ExitStatus>,
    conn: sys::Conn,
}

impl Connection {
    pub fn connect(endpoint: &str) -> io::Result<Self> {
        let (conn, hello, io) = sys::Conn::open(endpoint)?;
        if hello.kind != protocol::HELLO {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "keeper did not send HELLO"));
        }
        let mut connection = Self {
            child_pid: hello.a,
            version: hello.version,
            io,
            size: Size::default(),
            generation: 0,
            exit: None,
            conn,
        };
        // The keeper reports the current size right after HELLO.
        match connection.next_event()? {
            Event::Size { .. } => Ok(connection),
            Event::Exit(_) => {
                Err(io::Error::new(io::ErrorKind::InvalidData, "keeper did not report a size"))
            }
        }
    }

    pub fn child_pid(&self) -> u32 {
        self.child_pid
    }

    /// The keeper's protocol version.
    pub fn version(&self) -> u16 {
        self.version
    }

    /// The last size the keeper reported.
    pub fn size(&self) -> (Size, u64) {
        (self.size, self.generation)
    }

    /// The PTY streams, or `None` when the child had already exited.
    pub fn take_io(&mut self) -> Option<PtyIo> {
        self.io.take()
    }

    /// Asks the keeper to resize. The keeper answers every client with an
    /// `Event::Size` once the size is applied.
    pub fn resize(&self, size: Size) -> io::Result<()> {
        self.conn.send(&Frame::resize(size))
    }

    pub fn terminate(&self) -> io::Result<()> {
        self.conn.send(&Frame::new(protocol::TERMINATE, 0, 0, 0))
    }

    #[doc(hidden)]
    pub fn send_raw(&self, frame: &Frame) -> io::Result<()> {
        self.conn.send(frame)
    }

    /// Blocks for the next report, skipping kinds this client does not know.
    pub fn next_event(&mut self) -> io::Result<Event> {
        loop {
            let frame = self.conn.recv()?;
            match frame.kind {
                protocol::SIZE => {
                    self.size = frame.size();
                    self.generation = frame.c;
                    return Ok(Event::Size { size: self.size, generation: self.generation });
                }
                protocol::EXIT => {
                    let status = ExitStatus(frame.a);
                    self.exit = Some(status);
                    return Ok(Event::Exit(status));
                }
                _ => {}
            }
        }
    }

    /// Blocks until the keeper reports the child's exit.
    pub fn wait_exit(&mut self) -> io::Result<ExitStatus> {
        loop {
            if let Some(status) = self.exit {
                return Ok(status);
            }
            self.next_event()?;
        }
    }
}

fn bad_frame() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "keeper sent a malformed frame")
}

#[cfg(unix)]
mod sys {
    use super::*;
    use std::io::{Read, Write};
    use std::os::fd::{FromRawFd, OwnedFd, RawFd};
    use std::os::unix::net::UnixStream;
    use std::{mem, ptr};

    pub struct Conn(UnixStream);

    impl Conn {
        pub fn open(endpoint: &str) -> io::Result<(Self, Frame, Option<PtyIo>)> {
            let stream = UnixStream::connect(endpoint)?;
            let (frame, master) = recv_hello(&stream)?;
            let io = match master {
                Some(master) => {
                    let writer = File::from(master);
                    Some(PtyIo { reader: writer.try_clone()?, writer })
                }
                None => None,
            };
            Ok((Self(stream), frame, io))
        }

        pub fn send(&self, frame: &Frame) -> io::Result<()> {
            (&self.0).write_all(&frame.encode())
        }

        pub fn recv(&self) -> io::Result<Frame> {
            let mut buf = [0u8; protocol::FRAME_LEN];
            (&self.0).read_exact(&mut buf)?;
            Frame::decode(&buf).ok_or_else(bad_frame)
        }
    }

    /// Reads the 32-byte `HELLO` and the descriptor sent with it.
    fn recv_hello(stream: &UnixStream) -> io::Result<(Frame, Option<OwnedFd>)> {
        use std::os::fd::AsRawFd;
        let mut buf = [0u8; protocol::FRAME_LEN];
        let mut filled = 0;
        let mut master = None;
        while filled < buf.len() {
            let mut control = [0u64; 8];
            let mut iov = libc::iovec {
                iov_base: buf[filled..].as_mut_ptr().cast(),
                iov_len: buf.len() - filled,
            };
            // SAFETY: zeroed msghdr is valid; fields are set below.
            let mut msg: libc::msghdr = unsafe { mem::zeroed() };
            msg.msg_iov = &mut iov;
            msg.msg_iovlen = 1;
            msg.msg_control = control.as_mut_ptr().cast();
            msg.msg_controllen = size_of_val(&control) as _;
            // SAFETY: every buffer referenced by `msg` outlives the call.
            let n = unsafe { libc::recvmsg(stream.as_raw_fd(), &mut msg, 0) };
            if n < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if n == 0 {
                return Err(io::ErrorKind::UnexpectedEof.into());
            }
            filled += n as usize;
            // SAFETY: walks the control buffer the kernel just filled.
            unsafe {
                let mut cmsg = libc::CMSG_FIRSTHDR(&msg);
                while !cmsg.is_null() {
                    if (*cmsg).cmsg_level == libc::SOL_SOCKET
                        && (*cmsg).cmsg_type == libc::SCM_RIGHTS
                    {
                        let data_len = (*cmsg).cmsg_len as usize - libc::CMSG_LEN(0) as usize;
                        let data = libc::CMSG_DATA(cmsg).cast::<RawFd>();
                        for index in 0..data_len / size_of::<RawFd>() {
                            let fd = ptr::read_unaligned(data.add(index));
                            libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
                            let owned = OwnedFd::from_raw_fd(fd);
                            if master.is_none() {
                                master = Some(owned);
                            }
                        }
                    }
                    cmsg = libc::CMSG_NXTHDR(&msg, cmsg);
                }
            }
        }
        Ok((Frame::decode(&buf).ok_or_else(bad_frame)?, master))
    }
}

#[cfg(windows)]
mod sys {
    use super::*;
    use crate::win_io::{self, Handle};
    use std::os::windows::ffi::OsStrExt;
    use std::os::windows::io::{FromRawHandle, OwnedHandle};
    use std::ptr;
    use windows_sys::Win32::Foundation::{
        ERROR_PIPE_BUSY, GENERIC_READ, GENERIC_WRITE, HANDLE, INVALID_HANDLE_VALUE,
    };
    use windows_sys::Win32::Storage::FileSystem::{
        CreateFileW, FILE_FLAG_OVERLAPPED, OPEN_EXISTING,
    };
    use windows_sys::Win32::System::Pipes::WaitNamedPipeW;

    pub struct Conn(Handle);

    impl Conn {
        pub fn open(endpoint: &str) -> io::Result<(Self, Frame, Option<PtyIo>)> {
            let name: Vec<u16> = OsStr::new(endpoint).encode_wide().chain(Some(0)).collect();
            let mut attempts = 0;
            let handle = loop {
                // SAFETY: `name` is NUL-terminated and outlives the call.
                let handle = unsafe {
                    CreateFileW(
                        name.as_ptr(),
                        GENERIC_READ | GENERIC_WRITE,
                        0,
                        ptr::null(),
                        OPEN_EXISTING,
                        FILE_FLAG_OVERLAPPED,
                        ptr::null_mut(),
                    )
                };
                if handle != INVALID_HANDLE_VALUE {
                    break Handle(handle);
                }
                let error = io::Error::last_os_error();
                attempts += 1;
                if error.raw_os_error() != Some(ERROR_PIPE_BUSY as i32) || attempts > 20 {
                    return Err(error);
                }
                // SAFETY: `name` is NUL-terminated.
                unsafe { WaitNamedPipeW(name.as_ptr(), 1000) };
            };
            let conn = Self(handle);
            let hello = conn.recv()?;
            let io = if hello.kind == protocol::HELLO && hello.b != 0 && hello.c != 0 {
                // SAFETY: the keeper duplicated both handles into this process for us.
                let (writer, reader) = unsafe {
                    (
                        OwnedHandle::from_raw_handle(hello.b as usize as HANDLE),
                        OwnedHandle::from_raw_handle(hello.c as usize as HANDLE),
                    )
                };
                Some(PtyIo { reader: File::from(reader), writer: File::from(writer) })
            } else {
                None
            };
            Ok((conn, hello, io))
        }

        pub fn send(&self, frame: &Frame) -> io::Result<()> {
            win_io::write_all(&self.0, &frame.encode())
        }

        pub fn recv(&self) -> io::Result<Frame> {
            let mut buf = [0u8; protocol::FRAME_LEN];
            win_io::read_exact(&self.0, &mut buf)?;
            Frame::decode(&buf).ok_or_else(bad_frame)
        }
    }
}
