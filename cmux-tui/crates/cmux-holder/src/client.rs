//! The daemon's side of the holder link.

use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::{Child, ChildStdout, Command, Stdio};
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
    /// The holder's answer to an ADOPT (wire version 5), its segment
    /// dropped: [`HolderClient::adopted`] returns it with the segment.
    Adopted {
        chan: u32,
        oldest: u64,
        end: u64,
        /// The answer carried the ring's segment.
        ring: bool,
    },
}

/// The ring a holder writes an adopted terminal's output to
/// ([`Kind::Adopted`], wire version 5).
#[derive(Debug)]
pub struct Adopted {
    /// Offset of the oldest byte the ring keeps.
    pub oldest: u64,
    /// Offset after its newest byte.
    pub end: u64,
    /// The ring's segment (`None`: the ring is private).
    pub ring: Option<OwnedFd>,
}

/// How long a just-started holder may take to say `ready`. One that hangs
/// before it (a stall in its setup or its first exec) is killed then, so
/// it cannot hold up every terminal create for ever.
pub const READY_TIMEOUT: Duration = Duration::from_secs(10);

/// The first line a just-started holder prints on `stdout` (`ready` once it
/// listens), waiting at most `timeout`. An answer that ends without a
/// newline (the holder exited) is returned as it is; no answer in time is a
/// `TimedOut` error.
pub fn first_line_within(stdout: &mut ChildStdout, timeout: Duration) -> io::Result<String> {
    let deadline = Instant::now() + timeout;
    let mut line = Vec::new();
    let mut buf = [0u8; 256];
    while !line.contains(&b'\n') && line.len() < 4096 {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("the holder did not say ready within {timeout:?}"),
            ));
        }
        let mut poll_fd = libc::pollfd { fd: stdout.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let millis = i32::try_from(left.as_millis()).unwrap_or(i32::MAX).max(1);
        // SAFETY: polls one live pollfd; the timeout is the deadline left.
        let ready = unsafe { libc::poll(&mut poll_fd, 1, millis) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if ready == 0 {
            continue;
        }
        match stdout.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => line.extend_from_slice(buf.get(..n).unwrap_or_default()),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    let end = line.iter().position(|byte| *byte == b'\n').map_or(line.len(), |at| at + 1);
    line.truncate(end);
    Ok(String::from_utf8_lossy(&line).into_owned())
}

/// A terminal a holder started: its pid and the custody dups.
#[derive(Debug)]
pub struct Spawned {
    pub pid: i32,
    pub master: OwnedFd,
    /// The ring segment (wire version 4; `None` from an older holder).
    pub ring: Option<OwnedFd>,
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
    let mut stdout = child.stdout.take().ok_or_else(|| io::Error::other("no holder stdout"))?;
    let answer = first_line_within(&mut stdout, READY_TIMEOUT);
    if matches!(&answer, Ok(line) if line.trim() == "ready") {
        return Ok(child);
    }
    let _ = child.kill();
    let _ = child.wait();
    Err(match answer {
        Ok(line) => io::Error::other(format!("holder did not start: {line:?}")),
        Err(error) => error,
    })
}

/// Make the process `command` starts inherit only its stdio from this
/// one: every other descriptor is closed at its exec, also one that this
/// process holds without close-on-exec (a test runner's jobserver pipe,
/// say) and one another thread has not marked close-on-exec yet (on macOS
/// std marks a new socket or pipe only after the call that made it, and a
/// descriptor received over a link is marked after `recvmsg` returns).
/// A [`launch_with`] `configure` step for a test that counts a holder's
/// descriptors: an inherited descriptor counts in the holder's table, but
/// takes one of the slots under a lowered `RLIMIT_NOFILE` only when its
/// number is below that limit. Without this step, the holder's free
/// descriptors depend on the process that runs the test.
pub fn inherit_only_stdio(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    // Every descriptor of this process is numbered below its soft limit:
    // a new one gets the lowest free number, and nothing here lowers the
    // limit. The kernels keep that limit at or under 2^20 by default
    // (Linux `fs.nr_open`; macOS `kern.maxfilesperproc` is lower); the cap
    // keeps the loop short if a limit reads as unlimited.
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: getrlimit fills one rlimit.
    let soft = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } == 0 {
        limit.rlim_cur
    } else {
        // SAFETY: sysconf takes no pointers.
        unsafe { libc::sysconf(libc::_SC_OPEN_MAX) }.max(0) as libc::rlim_t
    };
    let end = soft.min(1 << 20) as libc::c_int;
    // SAFETY: the step runs in the child between fork and exec, after Rust
    // put the child's stdio on 0-2, and makes only `fcntl` calls, which are
    // async-signal-safe.
    unsafe {
        command.pre_exec(move || {
            for fd in 3..end {
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
            Ok(())
        });
    }
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
        Self::connect_as(socket, token, wire::VERSION)
    }

    /// [`Self::connect`], offering wire version `version` in the HELLO: an
    /// older daemon's link (a test of what an older build gets).
    pub fn connect_as(
        socket: &Path,
        token: &[u8; 32],
        version: u16,
    ) -> io::Result<(Self, Vec<Listed>)> {
        let stream = UnixStream::connect(socket)?;
        wire::tune_socket(stream.as_raw_fd());
        let mut client = Self {
            stream,
            reader: wire::Reader::default(),
            pending: VecDeque::new(),
            version: wire::MIN_VERSION,
        };
        client.send(Kind::Hello, 0, &Out::default().u16(version).bytes(token).0, None)?;
        let deadline = Instant::now() + Duration::from_secs(10);
        let count = loop {
            let frame = client.frame(deadline)?;
            match Kind::from_u16(frame.kind) {
                Some(Kind::Welcome) => {
                    let mut input = In(&frame.payload);
                    client.version = input.u16()?;
                    break input.u32()?;
                }
                Some(Kind::Error) => return Err(refusal(&frame.payload)),
                _ => continue,
            }
        };
        let mut listed = Vec::new();
        while listed.len() < count as usize {
            let frame = client.frame(deadline)?;
            if frame.kind == Kind::Listed as u16 {
                listed.push(Listed::decode(frame.chan, frame.flags, &frame.payload, frame.fds)?);
            }
        }
        Ok((client, listed))
    }

    /// The authenticated socket, the bytes already read past the handshake
    /// and the settled wire version (for [`crate::link::HolderLink`]).
    pub(crate) fn into_parts(self) -> (UnixStream, wire::Reader, u16) {
        (self.stream, self.reader, self.version)
    }

    /// End the link now, as a daemon's death does: the holder reads its
    /// end even while a process another thread just forked still holds a
    /// copy of the socket (until that child's exec closes it), which a
    /// plain drop would leave open.
    pub fn end(self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
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
        self.spawn_with_ring(chan, request).map(|spawned| (spawned.pid, spawned.master))
    }

    /// [`Self::spawn`], with the custody dup of the terminal's ring segment
    /// (wire version 4; `None` from an older holder).
    pub fn spawn_with_ring(&mut self, chan: u32, request: &SpawnRequest) -> io::Result<Spawned> {
        self.send(Kind::Spawn, chan, &request.encode(), None)?;
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let frame = self.frame(deadline)?;
            match Kind::from_u16(frame.kind) {
                Some(Kind::Spawned) if frame.chan == chan => {
                    let pid = In(&frame.payload).i32()?;
                    let mut fds = frame.fds.into_iter();
                    let master = fds.next().ok_or_else(|| io::Error::other("no master fd"))?;
                    return Ok(Spawned { pid, master, ring: fds.next() });
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

    /// Hand a running terminal and its ring segment to this holder (wire
    /// version 4): the holder continues the dead holder's ring, with every
    /// byte it read. `base` is where `prologue`'s screen is (the offset the
    /// daemon parsed), `resume` where a fresh ring would start. A holder of
    /// wire version 5 answers with the ring it writes ([`Self::adopted`]).
    pub fn adopt_with_ring(
        &mut self,
        chan: u32,
        id: &[u8; 16],
        (pid, base, resume): (i32, u64, u64),
        master: &OwnedFd,
        ring: &OwnedFd,
        prologue: &[u8],
    ) -> io::Result<()> {
        let payload = Out::default().i32(pid).u64(base).bytes(id).u64(resume).bytes(prologue).0;
        let fds = [master.as_raw_fd(), ring.as_raw_fd()];
        wire::send_frame(
            self.stream.as_raw_fd(),
            Kind::Adopt,
            wire::FLAG_RING,
            chan,
            &payload,
            &fds,
        )
    }

    /// The wire version the holder's WELCOME settled on.
    pub fn version(&self) -> u16 {
        self.version
    }

    pub fn attach(&mut self, chan: u32, from: u64) -> io::Result<()> {
        self.send(Kind::Attach, chan, &Out::default().u64(from).0, None)
    }

    /// [`Self::attach`] for a daemon that received up to `from` but parsed
    /// only up to `parsed` (wire version 5): the credit counts from `parsed`.
    pub fn attach_parsed(&mut self, chan: u32, from: u64, parsed: u64) -> io::Result<()> {
        self.send(Kind::Attach, chan, &Out::default().u64(from).u64(parsed).0, None)
    }

    /// The holder's answer to an ADOPT of `chan` (wire version 5): the ring
    /// it writes the terminal's output to. Other events wait for
    /// [`Self::next_event`].
    pub fn adopted(&mut self, chan: u32) -> io::Result<Adopted> {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let frame = self.frame(deadline)?;
            match Kind::from_u16(frame.kind) {
                Some(Kind::Adopted) if frame.chan == chan => {
                    let mut input = In(&frame.payload);
                    let (oldest, end) = (input.u64()?, input.u64()?);
                    return Ok(Adopted { oldest, end, ring: frame.fds.into_iter().next() });
                }
                Some(Kind::Error) if frame.chan == chan => {
                    return Err(io::Error::other(error_message(&frame.payload)));
                }
                _ => self.keep(frame)?,
            }
        }
    }

    /// [`Self::attach`] as a restarted daemon does: the prologue first.
    pub fn reattach(&mut self, chan: u32, from: u64) -> io::Result<()> {
        let payload = Out::default().u64(from).0;
        let flags = wire::FLAG_WITH_PROLOGUE;
        wire::send_frame(self.stream.as_raw_fd(), Kind::Attach, flags, chan, &payload, &[])
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

    /// Ask for an [`Event::Pong`] with `nonce`. The holder handles frames in
    /// order, so the PONG shows it finished every request sent before.
    pub fn ping(&mut self, nonce: u64) -> io::Result<()> {
        self.send(Kind::Ping, 0, &Out::default().u64(nonce).0, None)
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
            Some(Kind::Adopted) => Event::Adopted {
                chan,
                oldest: input.u64()?,
                end: input.u64()?,
                ring: !frame.fds.is_empty(),
            },
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
        wire::send_frame(self.stream.as_raw_fd(), kind, 0, chan, payload, &fds)
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

/// The error a holder's refusal of the HELLO stands for.
fn refusal(payload: &[u8]) -> io::Error {
    let code = In(payload.get(2..).unwrap_or_default()).u16().unwrap_or_default();
    if code == crate::holder::error_code::BAD_TOKEN {
        return io::Error::other("holder refused the token");
    }
    io::Error::other(format!("holder refused the link (code {code}): {}", error_message(payload)))
}
