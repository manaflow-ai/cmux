//! PTY custody (cx-6so.49 L1): the owner keeps a copy of a host's PTY
//! master, so the kernel does not hang up the shell when the host dies and
//! a replacement host (`adopt_launch.rs`) can serve the same session.
//!
//! The owner connects with its durable owner token, role admin, rights
//! exactly `ADMIN | CLIPBOARD_READ` (only the owner token grants
//! `CLIPBOARD_READ`, so this proves the owner) and `FLAG_PTY_CUSTODY` at the
//! current protocol version. The host answers `HostHello` echoing the flag,
//! then one `PtyCustody` frame (`version:u16=1, child_pid:u32,
//! session_id:u32`) whose bytes carry the master descriptor as
//! `SCM_RIGHTS`, and closes the connection. The connection takes no
//! snapshot, joins no stream and never claims the launch owner.

use std::os::fd::{FromRawFd, OwnedFd};
use std::sync::PoisonError;

use super::*;

const PTY_CUSTODY_VERSION: u16 = 1;
const PTY_CUSTODY_PAYLOAD_LEN: usize = 2 + 4 + 4;
const PTY_CUSTODY_FRAME_LEN: usize =
    crate::terminal_host_protocol::HEADER_LEN + PTY_CUSTODY_PAYLOAD_LEN;
const CUSTODY_REQUEST_ID: u64 = 1;

/// A duplicate of a terminal host's PTY master and the session it runs.
#[derive(Debug)]
pub struct PtyCustody {
    /// The PTY master, close-on-exec.
    pub master: OwnedFd,
    /// The session leader running in the PTY.
    pub child_pid: u32,
    /// Its session id (equal to `child_pid` for every current host).
    pub session_id: u32,
}

fn owner_rights() -> CapabilityRights {
    CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ
}

pub(super) fn encode_pty_custody(child_pid: u32, session_id: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(PTY_CUSTODY_PAYLOAD_LEN);
    payload.extend_from_slice(&PTY_CUSTODY_VERSION.to_le_bytes());
    payload.extend_from_slice(&child_pid.to_le_bytes());
    payload.extend_from_slice(&session_id.to_le_bytes());
    payload
}

pub(super) fn decode_pty_custody(payload: &[u8]) -> anyhow::Result<(u32, u32)> {
    let mut decoder = PayloadDecoder::new(payload);
    let version = decoder.u16()?;
    let child_pid = decoder.u32()?;
    let session_id = decoder.u32()?;
    decoder.finish()?;
    anyhow::ensure!(version == PTY_CUSTODY_VERSION, "unsupported PtyCustody version {version}");
    anyhow::ensure!(child_pid != 0 && session_id != 0, "PtyCustody names no process");
    Ok((child_pid, session_id))
}

/// Host side: answer an authenticated `FLAG_PTY_CUSTODY` hello, then close.
pub(super) fn serve(
    host: &HostShared,
    mut stream: UnixStream,
    hello_frame: &Frame,
    hello: &ClientHello,
    response: &HostHello,
) -> anyhow::Result<()> {
    if hello.role != ClientRole::Admin
        || response.granted_rights != owner_rights()
        || hello_frame.version != PROTOCOL_VERSION
        || response.selected_version != PROTOCOL_VERSION
        || hello_frame.flags != FLAG_PTY_CUSTODY
    {
        anyhow::bail!("terminal-host PTY custody denied");
    }
    let (child_pid, session_id) = {
        // While this lock is held and the child is unreaped, a spawned
        // child's PID cannot be reused (see signal_terminal_process_groups).
        let _signal = host.child_signal_lock.lock().unwrap_or_else(PoisonError::into_inner);
        let pid = host.pid.and_then(|pid| libc::pid_t::try_from(pid).ok()).filter(|pid| *pid > 0);
        let live = !host.dead.load(Ordering::Acquire)
            && !host.child_waitable.load(Ordering::Acquire)
            && !host.child_reaped.load(Ordering::Acquire)
            && host.child_signalable();
        let Some(pid) = pid.filter(|_| live) else {
            anyhow::bail!("terminal-host PTY custody refused: the child ended");
        };
        // SAFETY: getsid has no memory preconditions.
        let session = unsafe { libc::getsid(pid) };
        anyhow::ensure!(session == pid, "terminal-host child does not lead its session");
        (pid.unsigned_abs(), session.unsigned_abs())
    };
    let master = host.master.lock().unwrap_or_else(PoisonError::into_inner);
    let Some(master_fd) = master.as_raw_fd() else {
        anyhow::bail!("terminal-host PTY custody refused: no master descriptor");
    };
    let mut hello_response = Frame::new(MessageKind::HostHello, response.encode());
    hello_response.flags = FLAG_PTY_CUSTODY;
    hello_response.request_id = hello_frame.request_id;
    write_frame(&mut stream, &hello_response)?;
    let mut custody =
        Frame::new(MessageKind::PtyCustody, encode_pty_custody(child_pid, session_id));
    custody.request_id = hello_frame.request_id;
    let bytes = crate::terminal_host_protocol::encode_frame(&custody)?;
    // The master stays open for this host's lifetime; holding its lock keeps
    // the descriptor number valid while the kernel duplicates it.
    send_with_descriptor(&stream, &bytes, master_fd)?;
    drop(master);
    let _ = stream.shutdown(std::net::Shutdown::Both);
    Ok(())
}

/// Owner side: take custody of the PTY master of the host `record` names.
pub fn request_terminal_host_pty_custody(
    record: &TerminalHostRecord,
    record_path: &Path,
) -> anyhow::Result<PtyCustody> {
    validate_terminal_host_record(record_path, record)?;
    anyhow::ensure!(
        record.supports_pty_custody,
        "terminal host {} does not support PTY custody",
        record.terminal_id
    );
    let terminal_id = TerminalId::from_bytes(decode_hex_array(&record.terminal_id)?);
    let incarnation = HostIncarnation::from_bytes(decode_hex_array(&record.incarnation)?);
    let token = CapabilityToken::from_bytes(decode_hex_array(&record.owner_token)?);
    let mut stream = connect_with_retry(Path::new(&record.endpoint))
        .with_context(|| format!("connect terminal host at {}", record.endpoint))?;
    stream.set_read_timeout(Some(HOST_HANDSHAKE_TIMEOUT))?;
    stream.set_write_timeout(Some(HOST_HANDSHAKE_TIMEOUT))?;
    let hello = ClientHello {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        role: ClientRole::Admin,
        requested_rights: owner_rights(),
        terminal_id,
        token,
    };
    let mut hello_frame = hello.into_frame(CUSTODY_REQUEST_ID);
    hello_frame.flags = FLAG_PTY_CUSTODY;
    write_frame(&mut stream, &hello_frame)?;
    // Exact-length reads never consume bytes of the following custody
    // frame, whose first bytes carry the descriptor.
    let reply = read_required_frame(&mut stream, "PTY custody host hello")?;
    if reply.kind != MessageKind::HostHello
        || reply.version != PROTOCOL_VERSION
        || reply.flags != FLAG_PTY_CUSTODY
        || reply.request_id != CUSTODY_REQUEST_ID
        || reply.sequence != 0
    {
        anyhow::bail!("terminal host refused PTY custody");
    }
    let host_hello = HostHello::decode(&reply.payload)?;
    if host_hello.selected_version != PROTOCOL_VERSION
        || host_hello.terminal_id != terminal_id
        || host_hello.incarnation != incarnation
        || host_hello.granted_rights != owner_rights()
    {
        anyhow::bail!("terminal-host record identity does not match the custody host");
    }
    let (bytes, master) = receive_with_descriptor(&stream, PTY_CUSTODY_FRAME_LEN)?;
    let master =
        master.ok_or_else(|| anyhow::anyhow!("terminal host sent no PTY master descriptor"))?;
    let frame = read_frame(&mut bytes.as_slice(), PTY_CUSTODY_PAYLOAD_LEN)?
        .ok_or_else(|| anyhow::anyhow!("terminal host closed before PtyCustody"))?;
    if frame.kind != MessageKind::PtyCustody
        || frame.version != PROTOCOL_VERSION
        || frame.flags != 0
        || frame.request_id != CUSTODY_REQUEST_ID
        || frame.sequence != 0
    {
        anyhow::bail!("terminal host sent a malformed PtyCustody frame");
    }
    let (child_pid, session_id) = decode_pty_custody(&frame.payload)?;
    Ok(PtyCustody { master, child_pid, session_id })
}

/// An aligned control buffer for one descriptor.
#[repr(C, align(8))]
struct ControlBuffer([u8; 64]);

fn send_with_descriptor(
    stream: &UnixStream,
    bytes: &[u8],
    descriptor: RawFd,
) -> std_io::Result<()> {
    let mut control = ControlBuffer([0; 64]);
    let mut iov =
        libc::iovec { iov_base: bytes.as_ptr() as *mut libc::c_void, iov_len: bytes.len() };
    // SAFETY: CMSG_SPACE/CMSG_LEN are pure size computations.
    let (space, length) = unsafe {
        (
            libc::CMSG_SPACE(size_of::<libc::c_int>() as u32) as usize,
            libc::CMSG_LEN(size_of::<libc::c_int>() as u32) as usize,
        )
    };
    debug_assert!(space <= control.0.len());
    // SAFETY: zeroed msghdr is a valid empty message.
    let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
    message.msg_iov = &mut iov;
    message.msg_iovlen = 1;
    message.msg_control = control.0.as_mut_ptr().cast();
    message.msg_controllen = space as _;
    // SAFETY: the message owns a control buffer of `space` aligned bytes, so
    // the first header and its one-descriptor payload are in bounds.
    unsafe {
        let header = libc::CMSG_FIRSTHDR(&message);
        if header.is_null() {
            return Err(std_io::Error::other("no room for SCM_RIGHTS"));
        }
        (*header).cmsg_level = libc::SOL_SOCKET;
        (*header).cmsg_type = libc::SCM_RIGHTS;
        (*header).cmsg_len = length as _;
        std::ptr::write_unaligned(libc::CMSG_DATA(header).cast::<libc::c_int>(), descriptor);
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let flags = libc::MSG_NOSIGNAL;
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let flags = 0;
    let sent = loop {
        // SAFETY: a valid socket and a fully initialized message.
        let sent = unsafe { libc::sendmsg(stream.as_raw_fd(), &message, flags) };
        if sent >= 0 {
            break sent.unsigned_abs();
        }
        let error = std_io::Error::last_os_error();
        if error.kind() != std_io::ErrorKind::Interrupted {
            return Err(error);
        }
    };
    if sent == 0 {
        return Err(std_io::Error::new(std_io::ErrorKind::WriteZero, "PtyCustody not sent"));
    }
    // The descriptor travelled with the first byte; the rest is plain data.
    let mut writer = stream;
    writer.write_all(&bytes[sent.min(bytes.len())..])
}

fn receive_with_descriptor(
    stream: &UnixStream,
    length: usize,
) -> anyhow::Result<(Vec<u8>, Option<OwnedFd>)> {
    let mut bytes = vec![0u8; length];
    let mut received = 0;
    let mut descriptor: Option<OwnedFd> = None;
    while received < length {
        let mut control = ControlBuffer([0; 64]);
        let mut iov = libc::iovec {
            iov_base: bytes[received..].as_mut_ptr().cast(),
            iov_len: length - received,
        };
        // SAFETY: zeroed msghdr is a valid empty message.
        let mut message: libc::msghdr = unsafe { std::mem::zeroed() };
        message.msg_iov = &mut iov;
        message.msg_iovlen = 1;
        message.msg_control = control.0.as_mut_ptr().cast();
        message.msg_controllen = control.0.len() as _;
        #[cfg(any(target_os = "linux", target_os = "android"))]
        let flags = libc::MSG_CMSG_CLOEXEC;
        #[cfg(not(any(target_os = "linux", target_os = "android")))]
        let flags = 0;
        // SAFETY: a valid socket, buffer and control buffer for the call.
        let count = unsafe { libc::recvmsg(stream.as_raw_fd(), &mut message, flags) };
        if count < 0 {
            let error = std_io::Error::last_os_error();
            if error.kind() == std_io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error).context("receive PtyCustody");
        }
        for fd in take_descriptors(&message) {
            anyhow::ensure!(descriptor.is_none(), "terminal host sent more than one descriptor");
            set_cloexec(&fd)?;
            descriptor = Some(fd);
        }
        anyhow::ensure!(
            message.msg_flags & libc::MSG_CTRUNC == 0,
            "PtyCustody control data was truncated"
        );
        anyhow::ensure!(count > 0, "terminal host closed before PtyCustody");
        received += count.unsigned_abs();
    }
    Ok((bytes, descriptor))
}

/// Own every `SCM_RIGHTS` descriptor of a received message.
fn take_descriptors(message: &libc::msghdr) -> Vec<OwnedFd> {
    let mut descriptors = Vec::new();
    // SAFETY: the kernel filled the control buffer of `message`; the CMSG
    // macros walk only within msg_controllen.
    unsafe {
        let mut header = libc::CMSG_FIRSTHDR(message);
        while !header.is_null() {
            if (*header).cmsg_level == libc::SOL_SOCKET && (*header).cmsg_type == libc::SCM_RIGHTS {
                let data = libc::CMSG_DATA(header);
                let base = data.offset_from(header.cast::<u8>()).unsigned_abs();
                let payload = ((*header).cmsg_len as usize).saturating_sub(base);
                for index in 0..payload / size_of::<libc::c_int>() {
                    let fd = std::ptr::read_unaligned(
                        data.add(index * size_of::<libc::c_int>()).cast::<libc::c_int>(),
                    );
                    if fd >= 0 {
                        descriptors.push(OwnedFd::from_raw_fd(fd));
                    }
                }
            }
            header = libc::CMSG_NXTHDR(message, header);
        }
    }
    descriptors
}

fn set_cloexec(fd: &OwnedFd) -> std_io::Result<()> {
    // SAFETY: fcntl on a valid owned descriptor.
    let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
    // SAFETY: as above.
    if flags < 0
        || unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, flags | libc::FD_CLOEXEC) } < 0
    {
        return Err(std_io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pty_custody_payload_round_trips_and_rejects_bad_bounds() {
        let payload = encode_pty_custody(41, 41);
        assert_eq!(payload.len(), PTY_CUSTODY_PAYLOAD_LEN);
        assert_eq!(decode_pty_custody(&payload).unwrap(), (41, 41));
        assert!(decode_pty_custody(&payload[..9]).is_err(), "truncated");
        let mut long = payload.clone();
        long.push(0);
        assert!(decode_pty_custody(&long).is_err(), "trailing byte");
        let mut version = payload;
        version[0] = 2;
        assert!(decode_pty_custody(&version).is_err(), "unknown version");
        assert!(decode_pty_custody(&encode_pty_custody(0, 41)).is_err(), "no pid");
        assert!(decode_pty_custody(&encode_pty_custody(41, 0)).is_err(), "no session");
    }

    #[test]
    fn pty_custody_descriptor_crosses_a_socket_pair() {
        let (left, right) = UnixStream::pair().unwrap();
        let (pipe_read, mut pipe_write) = std::io::pipe().unwrap();
        let mut custody = Frame::new(MessageKind::PtyCustody, encode_pty_custody(7, 7));
        custody.request_id = CUSTODY_REQUEST_ID;
        let bytes = crate::terminal_host_protocol::encode_frame(&custody).unwrap();
        send_with_descriptor(&left, &bytes, pipe_read.as_raw_fd()).unwrap();
        drop(pipe_read);
        let (received, fd) = receive_with_descriptor(&right, PTY_CUSTODY_FRAME_LEN).unwrap();
        assert_eq!(received, bytes);
        let fd = fd.expect("descriptor");
        // SAFETY: F_GETFD on the received, owned descriptor.
        assert_ne!(unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC, 0);
        pipe_write.write_all(b"x").unwrap();
        let mut byte = [0u8; 1];
        File::from(fd).read_exact(&mut byte).unwrap();
        assert_eq!(&byte, b"x");
    }
}
