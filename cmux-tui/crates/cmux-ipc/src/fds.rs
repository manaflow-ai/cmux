//! File descriptors over a Unix stream socket (`SCM_RIGHTS`).
//!
//! A frame that carries descriptors sends them with its first byte
//! ([`send_with_fds`]). The receiver reads with [`FdReceiver::recv`], which
//! queues every descriptor that arrives in arrival order; the frame decoder
//! knows from the frame header how many a frame takes and pops them with
//! [`FdReceiver::take`]. This is Chromium's model: `mojo/core/channel_posix.cc`
//! keeps `incoming_fds_` as a FIFO filled by `SocketRecvmsg`
//! (`mojo/public/cpp/platform/socket_utils_posix.cc`) and drained per message,
//! and `base/posix/unix_domain_socket.cc` (`RecvMsgWithFlags`) fails a read
//! whose control data was truncated (`MSG_CTRUNC`) instead of misnumbering the
//! descriptors after it.
//!
//! Every received descriptor is close-on-exec once [`FdReceiver::recv`]
//! returns: atomically on Linux (`MSG_CMSG_CLOEXEC`); on macOS with
//! `F_SETFD` right after the `recvmsg`. That macOS window is not atomic: a
//! child another thread spawns in it inherits the descriptor unless it is
//! spawned with `POSIX_SPAWN_CLOEXEC_DEFAULT` (`cmux-process`). The `between`
//! seam of [`FdReceiver::recv`] lets a test spawn inside that window.

use std::collections::VecDeque;
use std::fmt;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

/// Descriptors one frame may carry. The holder's frames carry at most two
/// (a PTY master and its ring segment); `base/posix/unix_domain_socket.cc`
/// caps a message the same way (`kMaxFileDescriptors`).
pub const MAX_FDS_PER_FRAME: usize = 4;

/// Descriptors one `recvmsg` may carry (Linux `SCM_MAX_FD`). The kernel may
/// deliver the descriptors of many frames in one read (the holder's WELCOME
/// passes one per terminal), so the control buffer is sized for the most one
/// read can bring, not for one frame.
pub const MAX_RECV_FDS: usize = 253;

/// A descriptor exchange that broke the wire's rules. The stream is lost:
/// the receiver can no longer tell which descriptor belongs to which frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FdBadMessage {
    /// The kernel had more descriptors than the control buffer holds
    /// (`MSG_CTRUNC`) and closed the rest.
    ControlTruncated,
    /// A frame asked to send or take more than [`MAX_FDS_PER_FRAME`].
    TooManyFds { count: usize },
}

impl fmt::Display for FdBadMessage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ControlTruncated => f.write_str("descriptors were truncated (MSG_CTRUNC)"),
            Self::TooManyFds { count } => {
                write!(f, "a frame carries {count} descriptors, more than {MAX_FDS_PER_FRAME}")
            }
        }
    }
}

impl std::error::Error for FdBadMessage {}

impl FdBadMessage {
    /// This error as an `io::Error` whose source is `self`
    /// (`InvalidData` for a received stream, `InvalidInput` for a send).
    pub fn into_io(self, kind: io::ErrorKind) -> io::Error {
        io::Error::new(kind, self)
    }
}

/// Write all of `bytes`, passing `fds` with the first byte. Blocking.
pub fn send_all(fd: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<()> {
    let mut sent = send_with_fds(fd, bytes, fds)?;
    while sent < bytes.len() {
        sent += send_with_fds(fd, &bytes[sent..], &[])?;
    }
    Ok(())
}

/// One `sendmsg` of `bytes` with `fds` as `SCM_RIGHTS`. Returns bytes sent.
/// More than [`MAX_FDS_PER_FRAME`] descriptors is an `InvalidInput` error
/// whose source is [`FdBadMessage::TooManyFds`]; nothing is sent then.
pub fn send_with_fds(fd: RawFd, bytes: &[u8], fds: &[RawFd]) -> io::Result<usize> {
    if fds.len() > MAX_FDS_PER_FRAME {
        return Err(
            FdBadMessage::TooManyFds { count: fds.len() }.into_io(io::ErrorKind::InvalidInput)
        );
    }
    let mut iov =
        libc::iovec { iov_base: bytes.as_ptr() as *mut libc::c_void, iov_len: bytes.len() };
    let space = if fds.is_empty() {
        0
    } else {
        // SAFETY: CMSG_SPACE computes a size from a length.
        unsafe { libc::CMSG_SPACE(size_of_val(fds) as u32) as usize }
    };
    let mut control = vec![0u8; space];
    // SAFETY: zeroed msghdr is a valid empty header.
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    if !fds.is_empty() {
        msg.msg_control = control.as_mut_ptr().cast();
        msg.msg_controllen = space as _;
        // SAFETY: the control buffer holds one cmsg of CMSG_SPACE(fds) bytes.
        unsafe {
            let cmsg = libc::CMSG_FIRSTHDR(&msg);
            (*cmsg).cmsg_level = libc::SOL_SOCKET;
            (*cmsg).cmsg_type = libc::SCM_RIGHTS;
            (*cmsg).cmsg_len = libc::CMSG_LEN(size_of_val(fds) as u32) as _;
            std::ptr::copy_nonoverlapping(
                fds.as_ptr(),
                libc::CMSG_DATA(cmsg).cast::<RawFd>(),
                fds.len(),
            );
        }
    }
    loop {
        // SAFETY: msg points at live buffers for the call.
        let n = unsafe { libc::sendmsg(fd, &msg, SEND_FLAGS) };
        if n >= 0 {
            return Ok(n as usize);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

/// `sendmsg` flags: a write to a gone peer is EPIPE, not SIGPIPE (macOS
/// gets that from `SO_NOSIGPIPE` on the socket instead).
#[cfg(target_os = "linux")]
const SEND_FLAGS: libc::c_int = libc::MSG_NOSIGNAL;
#[cfg(not(target_os = "linux"))]
const SEND_FLAGS: libc::c_int = 0;

/// `recvmsg` flags: received descriptors arrive close-on-exec where the
/// kernel can do that atomically.
#[cfg(target_os = "linux")]
const RECV_FLAGS: libc::c_int = libc::MSG_CMSG_CLOEXEC;
#[cfg(not(target_os = "linux"))]
const RECV_FLAGS: libc::c_int = 0;

/// The receiving end of a descriptor-passing stream: the `recvmsg` control
/// buffer (allocated on the first read) and the FIFO of descriptors that
/// arrived but no frame took yet. Dropping it closes the queued ones.
#[derive(Debug)]
pub struct FdReceiver {
    /// Descriptors one read may bring; sizes `control`.
    capacity: usize,
    control: Vec<u8>,
    queue: VecDeque<OwnedFd>,
}

impl Default for FdReceiver {
    fn default() -> Self {
        Self::with_capacity(MAX_RECV_FDS)
    }
}

impl FdReceiver {
    /// A receiver whose reads take at most `capacity` descriptors each; a
    /// read that brings more fails with [`FdBadMessage::ControlTruncated`].
    pub fn with_capacity(capacity: usize) -> Self {
        Self { capacity, control: Vec::new(), queue: VecDeque::new() }
    }

    /// Descriptors that arrived and no frame took yet.
    pub fn queued(&self) -> usize {
        self.queue.len()
    }

    /// The next `count` queued descriptors in arrival order: fewer when fewer
    /// are queued (the frame decoder checks what it got). More than
    /// [`MAX_FDS_PER_FRAME`] is [`FdBadMessage::TooManyFds`] and takes none.
    pub fn take(&mut self, count: usize) -> Result<Vec<OwnedFd>, FdBadMessage> {
        if count > MAX_FDS_PER_FRAME {
            return Err(FdBadMessage::TooManyFds { count });
        }
        let count = count.min(self.queue.len());
        Ok(self.queue.drain(..count).collect())
    }

    /// One `recvmsg` of at most `max` bytes appended to `buf`; the
    /// descriptors it brings are queued after `between` saw them (before
    /// they are made close-on-exec on macOS). Returns the bytes read, 0 at
    /// end of stream.
    ///
    /// Control data the kernel truncated (`MSG_CTRUNC`) fails the read with
    /// an `InvalidData` error whose source is
    /// [`FdBadMessage::ControlTruncated`], as does a descriptor that cannot
    /// be made close-on-exec: the descriptors of that read are closed then
    /// and the stream is lost, rather than handing a later frame the wrong
    /// descriptor or keeping one every later child inherits. Linux closes
    /// the descriptors it truncated; XNU has already installed them before it
    /// truncates the control data, so on macOS those stay open in this process.
    pub fn recv(
        &mut self,
        fd: RawFd,
        buf: &mut Vec<u8>,
        max: usize,
        between: impl FnOnce(&[OwnedFd]),
    ) -> io::Result<usize> {
        if self.control.is_empty() {
            // SAFETY: CMSG_SPACE computes a size from a length.
            let space =
                unsafe { libc::CMSG_SPACE((self.capacity * size_of::<RawFd>()) as u32) as usize };
            self.control = vec![0u8; space];
        }
        buf.reserve(max);
        let len = buf.len();
        let room = (buf.capacity() - len).min(max);
        let spare = &mut buf.spare_capacity_mut()[..room];
        let mut iov = libc::iovec { iov_base: spare.as_mut_ptr().cast(), iov_len: room };
        // SAFETY: zeroed msghdr is a valid empty header.
        let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
        msg.msg_iov = &mut iov;
        msg.msg_iovlen = 1;
        msg.msg_control = self.control.as_mut_ptr().cast();
        msg.msg_controllen = self.control.len() as _;
        let n = loop {
            // SAFETY: msg points at `room` bytes of `buf`'s spare capacity
            // and at the control buffer, both live for the call.
            let n = unsafe { libc::recvmsg(fd, &mut msg, RECV_FLAGS) };
            if n >= 0 {
                break n as usize;
            }
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        };
        // SAFETY: recvmsg initialized `n <= room` bytes past `len`.
        unsafe { buf.set_len(len + n) };
        let fds = received(&msg);
        if msg.msg_flags & libc::MSG_CTRUNC != 0 {
            return Err(FdBadMessage::ControlTruncated.into_io(io::ErrorKind::InvalidData));
        }
        between(&fds);
        if RECV_FLAGS == 0 {
            for fd in &fds {
                // SAFETY: F_SETFD on a descriptor this call owns.
                if unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
                    return Err(io::Error::last_os_error());
                }
            }
        }
        self.queue.extend(fds);
        Ok(n)
    }
}

/// The descriptors in the `SCM_RIGHTS` messages of a control buffer
/// `recvmsg` filled, owned at once so every one closes on any early return.
fn received(msg: &libc::msghdr) -> Vec<OwnedFd> {
    let mut fds = Vec::new();
    // SAFETY: walking the control buffer recvmsg filled, within msg_controllen.
    unsafe {
        let mut cmsg = libc::CMSG_FIRSTHDR(msg);
        while !cmsg.is_null() {
            if (*cmsg).cmsg_level == libc::SOL_SOCKET && (*cmsg).cmsg_type == libc::SCM_RIGHTS {
                let data = libc::CMSG_DATA(cmsg).cast::<RawFd>();
                let header = libc::CMSG_LEN(0) as usize;
                let count = ((*cmsg).cmsg_len as usize).saturating_sub(header) / size_of::<RawFd>();
                for index in 0..count {
                    fds.push(OwnedFd::from_raw_fd(std::ptr::read_unaligned(data.add(index))));
                }
            }
            cmsg = libc::CMSG_NXTHDR(msg, cmsg);
        }
    }
    fds
}
