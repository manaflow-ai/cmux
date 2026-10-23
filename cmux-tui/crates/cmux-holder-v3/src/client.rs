//! The daemon's side of the holder link.

use std::collections::VecDeque;
use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use crate::wire::{self, In, Kind, Out};
use crate::{ExitStatus, Listed, SpawnRequest};

/// Something the holder sent about a terminal.
#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    Data {
        chan: u32,
        offset: u64,
        bytes: Vec<u8>,
    },
    /// The terminal's prologue: a VT replay of its screen at `base`.
    Prologue {
        chan: u32,
        base: u64,
        bytes: Vec<u8>,
    },
    Gap {
        chan: u32,
        requested: u64,
        oldest: u64,
    },
    Exit {
        chan: u32,
        status: ExitStatus,
        end: u64,
    },
    Error {
        chan: u32,
        request_kind: u16,
        code: u16,
        message: String,
    },
    Pong {
        nonce: u64,
    },
}

/// Start a holder process serving `socket`, wait until it listens.
pub fn launch(binary: &Path, socket: &Path, token: &[u8; 32]) -> io::Result<Child> {
    launch_with(binary, socket, token, |_| {})
}

/// [`launch`], with `configure` adding arguments or environment to the
/// holder's command (`--idle-exit-ms`, [`crate::NOFILE_SOFT_ENV`]).
pub fn launch_with(
    binary: &Path,
    socket: &Path,
    token: &[u8; 32],
    configure: impl FnOnce(&mut Command),
) -> io::Result<Child> {
    let mut command = Command::new(binary);
    command
        .arg("--socket")
        .arg(socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    configure(&mut command);
    let mut child = command.spawn()?;
    let hex: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
    let mut stdin = child.stdin.take().ok_or_else(|| io::Error::other("no holder stdin"))?;
    stdin.write_all(format!("{hex}\n").as_bytes())?;
    drop(stdin);
    let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no holder stdout"))?;
    let mut line = String::new();
    BufReader::new(stdout).read_line(&mut line)?;
    if line.trim() != "ready" {
        let _ = child.kill();
        let _ = child.wait();
        return Err(io::Error::other(format!("holder did not start: {line:?}")));
    }
    Ok(child)
}

/// An authenticated link to a holder.
pub struct HolderClient {
    stream: UnixStream,
    reader: wire::Reader,
    pending: VecDeque<Event>,
    /// The wire version the holder's WELCOME settled on.
    version: u16,
}

impl HolderClient {
    /// Connect and authenticate; returns the terminals the holder runs.
    pub fn connect(socket: &Path, token: &[u8; 32]) -> io::Result<(Self, Vec<Listed>)> {
        let stream = UnixStream::connect(socket)?;
        wire::tune_socket(stream.as_raw_fd());
        let mut client = Self {
            stream,
            reader: wire::Reader::default(),
            pending: VecDeque::new(),
            version: wire::MIN_VERSION,
        };
        client.send(Kind::Hello, 0, &Out::default().u16(wire::VERSION).bytes(token).0, None)?;
        let deadline = Instant::now() + Duration::from_secs(10);
        let count = loop {
            let frame = client.frame(deadline)?;
            match Kind::from_u16(frame.kind) {
                Some(Kind::Welcome) => {
                    let mut input = In(&frame.payload);
                    client.version = input.u16()?;
                    break input.u32()?;
                }
                Some(Kind::Error) => return Err(io::Error::other("holder refused the token")),
                _ => continue,
            }
        };
        let mut listed = Vec::new();
        while listed.len() < count as usize {
            let mut frame = client.frame(deadline)?;
            if frame.kind == Kind::Listed as u16 {
                listed.push(Listed::decode(frame.chan, &frame.payload, frame.fds.pop())?);
            }
        }
        Ok((client, listed))
    }

    /// The authenticated socket, the bytes already read past the handshake
    /// and the settled wire version (for [`crate::link::HolderLink`]).
    pub(crate) fn into_parts(self) -> (UnixStream, wire::Reader, u16) {
        (self.stream, self.reader, self.version)
    }

    /// Whether the holder sends at most [`wire::CREDIT_WINDOW`] past the
    /// last [`Self::ack`] (wire version 2).
    pub fn has_credit(&self) -> bool {
        self.version >= 2
    }

    /// Tell the holder this client parsed `chan`'s output before `offset`.
    pub fn ack(&mut self, chan: u32, offset: u64) -> io::Result<()> {
        self.send(Kind::Ack, chan, &Out::default().u64(offset).0, None)
    }

    /// Start `request` on channel `chan`. Returns the child's pid and the
    /// daemon's custody dup of the PTY master.
    pub fn spawn(&mut self, chan: u32, request: &SpawnRequest) -> io::Result<(i32, OwnedFd)> {
        self.send(Kind::Spawn, chan, &request.encode(), None)?;
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let mut frame = self.frame(deadline)?;
            match Kind::from_u16(frame.kind) {
                Some(Kind::Spawned) if frame.chan == chan => {
                    let pid = In(&frame.payload).i32()?;
                    let fd = frame.fds.pop().ok_or_else(|| io::Error::other("no master fd"))?;
                    return Ok((pid, fd));
                }
                Some(Kind::Error) if frame.chan == chan => {
                    return Err(io::Error::other(error_message(&frame.payload)));
                }
                _ => self.keep(frame)?,
            }
        }
    }

    /// Hand a running terminal to this holder: its master (a dup the daemon
    /// kept), its pid, and the offset its output continues from.
    pub fn adopt(
        &mut self,
        chan: u32,
        id: &[u8; 16],
        pid: i32,
        base: u64,
        master: &OwnedFd,
    ) -> io::Result<()> {
        let payload = Out::default().i32(pid).u64(base).bytes(id).0;
        self.send(Kind::Adopt, chan, &payload, Some(master))
    }

    pub fn attach(&mut self, chan: u32, from: u64) -> io::Result<()> {
        self.send(Kind::Attach, chan, &Out::default().u64(from).0, None)
    }

    /// [`Self::attach`] as a restarted daemon does: the prologue first.
    pub fn reattach(&mut self, chan: u32, from: u64) -> io::Result<()> {
        let frame = wire::encode_flagged(
            Kind::Attach,
            wire::FLAG_WITH_PROLOGUE,
            chan,
            &Out::default().u64(from).0,
        );
        wire::send_all(self.stream.as_raw_fd(), &frame, &[])
    }

    /// Hand the holder a VT replay of `chan`'s screen at offset `base`.
    pub fn snapshot(&mut self, chan: u32, base: u64, replay: &[u8]) -> io::Result<()> {
        self.send(Kind::Snapshot, chan, &Out::default().u64(base).bytes(replay).0, None)
    }

    /// Leave `chan` on purpose (a daemon shutdown).
    pub fn detach(&mut self, chan: u32) -> io::Result<()> {
        self.send(Kind::Detach, chan, &[], None)
    }

    pub fn write(&mut self, chan: u32, bytes: &[u8]) -> io::Result<()> {
        self.send(Kind::Write, chan, bytes, None)
    }

    pub fn resize(&mut self, chan: u32, cols: u16, rows: u16) -> io::Result<()> {
        self.send(Kind::Resize, chan, &Out::default().u16(cols).u16(rows).u16(0).u16(0).0, None)
    }

    pub fn close(&mut self, chan: u32, grace_ms: u32) -> io::Result<()> {
        self.send(Kind::Close, chan, &Out::default().u32(grace_ms).0, None)
    }

    /// The next event, waiting at most until `deadline`.
    pub fn next_event(&mut self, deadline: Instant) -> io::Result<Event> {
        if let Some(event) = self.pending.pop_front() {
            return Ok(event);
        }
        loop {
            let frame = self.frame(deadline)?;
            self.keep(frame)?;
            if let Some(event) = self.pending.pop_front() {
                return Ok(event);
            }
        }
    }

    fn keep(&mut self, frame: wire::Frame) -> io::Result<()> {
        let chan = frame.chan;
        let mut input = In(&frame.payload);
        let event = match Kind::from_u16(frame.kind) {
            Some(Kind::Data) if frame.flags & wire::FLAG_PROLOGUE != 0 => {
                let base = input.u64()?;
                Event::Prologue { chan, base, bytes: input.rest().to_vec() }
            }
            Some(Kind::Data) => {
                let offset = input.u64()?;
                Event::Data { chan, offset, bytes: input.rest().to_vec() }
            }
            Some(Kind::Gap) => Event::Gap { chan, requested: input.u64()?, oldest: input.u64()? },
            Some(Kind::Exit) => {
                let (kind, code, end) = (input.u8()?, input.i32()?, input.u64()?);
                Event::Exit { chan, status: ExitStatus::decode(kind, code), end }
            }
            Some(Kind::Error) => Event::Error {
                chan,
                request_kind: input.u16()?,
                code: input.u16()?,
                message: String::from_utf8_lossy(input.rest()).into_owned(),
            },
            Some(Kind::Pong) => Event::Pong { nonce: input.u64()? },
            _ => return Ok(()),
        };
        self.pending.push_back(event);
        Ok(())
    }

    fn send(
        &mut self,
        kind: Kind,
        chan: u32,
        payload: &[u8],
        fd: Option<&OwnedFd>,
    ) -> io::Result<()> {
        let fds: Vec<_> = fd.map(AsRawFd::as_raw_fd).into_iter().collect();
        wire::send_all(self.stream.as_raw_fd(), &wire::encode(kind, chan, payload), &fds)
    }

    fn frame(&mut self, deadline: Instant) -> io::Result<wire::Frame> {
        loop {
            if let Some(frame) = self.reader.next_frame()? {
                return Ok(frame);
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "holder did not answer"));
            }
            match self.stream.set_read_timeout(Some(left)) {
                Ok(()) => {}
                // macOS fails setsockopt with EINVAL once the peer closed
                // the link; a read then never blocks, and it still returns
                // the frames the holder sent before it closed (SUPERSEDED).
                Err(error) if error.raw_os_error() == Some(libc::EINVAL) => {}
                Err(error) => return Err(error),
            }
            match self.reader.fill(self.stream.as_raw_fd()) {
                Ok(true) => {}
                Ok(false) => {
                    return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "holder link closed"));
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => return Err(error),
            }
        }
    }
}

fn error_message(payload: &[u8]) -> String {
    String::from_utf8_lossy(payload.get(4..).unwrap_or_default()).into_owned()
}
