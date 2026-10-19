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

use std::os::fd::OwnedFd;
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
pub(crate) fn serve(
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

impl PtyCustody {
    /// Whether the session leader still runs (not a zombie) and leads its
    /// session, so a replacement host could serve it.
    pub fn session_alive(&self) -> bool {
        match (libc::pid_t::try_from(self.child_pid), libc::pid_t::try_from(self.session_id)) {
            (Ok(pid), Ok(session)) => adopted_child::leads_session(pid, session),
            _ => false,
        }
    }
}

impl HostAttachment {
    /// Whether this attachment holds its host's PTY master.
    pub(crate) fn holds_pty_custody(&self) -> bool {
        self.pty_custody.is_some()
    }

    /// Keep `custody` for this attachment's host. It is released with the
    /// attachment: when the terminal ends, is closed or its Surface drops.
    pub(crate) fn keep_pty_custody(&mut self, custody: PtyCustody) {
        self.pty_custody = Some(custody);
    }

    /// Take the held PTY master, to start a replacement host on it.
    pub(crate) fn take_pty_custody(&mut self) -> Option<PtyCustody> {
        self.pty_custody.take()
    }
}

fn send_with_descriptor(
    stream: &UnixStream,
    bytes: &[u8],
    descriptor: RawFd,
) -> std_io::Result<()> {
    cmux_unix_socket::descriptor::send(stream, bytes, descriptor)
}

fn receive_with_descriptor(
    stream: &UnixStream,
    length: usize,
) -> anyhow::Result<(Vec<u8>, Option<OwnedFd>)> {
    Ok(cmux_unix_socket::descriptor::receive(stream, length)?)
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
