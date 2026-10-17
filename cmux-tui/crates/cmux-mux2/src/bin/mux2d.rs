//! `mux2d`: the terminal server. One process and one thread for every
//! terminal of a user. A kqueue loop reads each PTY and each client socket;
//! nothing else runs per terminal (no helper process, no thread).
//!
//! Correctness rules:
//! - Every PTY byte reaches the VT parser, in order. Parsing may be batched
//!   while nobody watches the terminal, but a batch is flushed before any
//!   operation that reads or changes terminal state (screen, replay, attach,
//!   resize, exit) and at once when the bytes carry a query the program
//!   waits on, so replies are never late.
//! - Attached clients receive a snapshot, then exactly the byte stream the
//!   server's parser accepted after it. A client that falls too far behind,
//!   or a terminal that is resized, gets a fresh snapshot instead of a gap.
//! - The server never blocks: PTY input and client output are queued and
//!   written when the descriptor is writable.

use std::collections::{HashMap, VecDeque};
use std::ffi::{CString, OsStr};
use std::io;
use std::os::fd::RawFd;
use std::os::unix::ffi::OsStrExt;
use std::sync::{Arc, Mutex};

use cmux_mux2::{self as proto, Reader};
use ghostty_vt::{Callbacks, Terminal};

const READ_CHUNK: usize = 64 << 10;
/// Most PTY bytes read for one terminal per event, so one busy terminal
/// cannot starve the others (kqueue is level-triggered and fires again).
const READ_BUDGET: usize = 1 << 20;
/// Unwatched output is parsed in batches of this size.
const PARSE_BATCH: usize = 1 << 20;
/// An attached client further behind than this is resynced with a snapshot.
const CLIENT_BACKLOG_MAX: usize = 16 << 20;
const SCROLLBACK_BYTES: usize = 10_000_000;
/// Output a dead child's descendants may still write before EXIT is sent.
const EXIT_DRAIN_MAX: usize = 16 << 20;

const TOKEN_LISTEN: u64 = 0;
const KIND_CONN: u64 = 1 << 32;
const KIND_PTY: u64 = 2 << 32;
const KIND_PROC: u64 = 3 << 32;
const INDEX_MASK: u64 = 0xffff_ffff;

struct Term {
    pid: libc::pid_t,
    master: RawFd,
    vt: Terminal,
    cols: u16,
    rows: u16,
    /// PTY bytes not yet given to the parser.
    pending: Vec<u8>,
    /// Bytes the parser asked to write back to the program (query replies).
    replies: Arc<Mutex<Vec<u8>>>,
    /// Bytes queued for the program's input (client writes and replies).
    input: VecDeque<u8>,
    input_armed: bool,
    attached: Vec<u32>,
    waiters: Vec<u32>,
    exit: Option<i32>,
    pty_open: bool,
    bytes_in: u64,
}

struct Conn {
    fd: RawFd,
    inbuf: Vec<u8>,
    /// Whole frames waiting to be written; `front_sent` bytes of the first
    /// one are already on the wire.
    out: VecDeque<Vec<u8>>,
    front_sent: usize,
    queued: usize,
    attached: Option<u32>,
    write_armed: bool,
    read_armed: bool,
    closing: bool,
}

impl Conn {
    /// Drops terminal-stream frames (OUTPUT, SNAPSHOT) not yet started, so a
    /// resync never cuts a frame and never loses a reply to a request.
    fn drop_unstarted(&mut self) {
        let started = usize::from(self.front_sent > 0);
        let mut index = 0;
        self.out.retain(|frame| {
            let keep = index < started || !matches!(frame[4], proto::OUTPUT | proto::SNAPSHOT);
            index += 1;
            keep
        });
        self.queued = self.out.iter().map(Vec::len).sum::<usize>() - self.front_sent;
    }
}

struct Server {
    kq: RawFd,
    listen: RawFd,
    terms: HashMap<u32, Term>,
    conns: HashMap<u32, Conn>,
    next_term: u32,
    next_conn: u32,
    buf: Vec<u8>,
    shutdown: bool,
}

fn cvt(r: libc::c_int) -> io::Result<libc::c_int> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

fn set_nonblock_cloexec(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl on a descriptor this process owns.
    unsafe {
        let fl = cvt(libc::fcntl(fd, libc::F_GETFL))?;
        cvt(libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK))?;
        cvt(libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC))?;
    }
    Ok(())
}

/// True when `data` holds a sequence the program waits on for a reply.
/// Conservative: a false positive only costs an early parse.
fn needs_immediate_parse(data: &[u8]) -> bool {
    let mut i = 0;
    while i < data.len() {
        match data[i] {
            0x05 => return true, // ENQ answerback
            0x1b => {
                let Some(&next) = data.get(i + 1) else { return true };
                match next {
                    // OSC, DCS, APC, PM, SOS: color/title queries, XTGETTCAP,
                    // DECRQSS, kitty graphics queries. DECID (ESC Z) is DA1.
                    b']' | b'P' | b'_' | b'^' | b'X' | b'Z' => return true,
                    b'[' => {
                        let mut j = i + 2;
                        // Parameters and intermediates; C0 controls other
                        // than ESC, CAN and SUB execute inside a CSI without
                        // ending it.
                        while j < data.len()
                            && ((0x20..0x40).contains(&data[j])
                                || (data[j] < 0x20 && !matches!(data[j], 0x1b | 0x18 | 0x1a)))
                        {
                            j += 1;
                        }
                        let Some(&fin) = data.get(j) else { return true };
                        // DA (c), DSR/CPR (n), DECRQM ($p), XTVERSION/kitty
                        // keyboard (q, u), window reports (t), DECREQTPARM (x).
                        if matches!(fin, b'c' | b'n' | b'p' | b'q' | b't' | b'u' | b'x') {
                            return true;
                        }
                        i = j;
                    }
                    _ => {}
                }
            }
            // C1 forms of CSI/OSC/DCS/APC/PM/SOS. UTF-8 continuation bytes
            // share this range, so non-ASCII text parses early; that is safe.
            0x90 | 0x98 | 0x9a | 0x9b | 0x9d..=0x9f => return true,
            _ => {}
        }
        i += 1;
    }
    false
}

impl Server {
    fn kev(
        &self,
        ident: usize,
        filter: i16,
        flags: u16,
        fflags: u32,
        udata: u64,
    ) -> io::Result<()> {
        // SAFETY: zeroed kevent is a valid value; fields are set below.
        let mut ev: libc::kevent = unsafe { std::mem::zeroed() };
        ev.ident = ident;
        ev.filter = filter;
        ev.flags = flags;
        ev.fflags = fflags;
        ev.udata = udata as usize as *mut libc::c_void;
        // SAFETY: one valid changelist entry, no event list.
        cvt(unsafe { libc::kevent(self.kq, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null()) })?;
        Ok(())
    }

    fn run(&mut self) -> io::Result<()> {
        // SAFETY: zeroed kevents are valid out-buffers.
        let mut events: Vec<libc::kevent> = vec![unsafe { std::mem::zeroed() }; 256];
        while !self.shutdown {
            // SAFETY: events has the capacity passed.
            let n = unsafe {
                libc::kevent(
                    self.kq,
                    std::ptr::null(),
                    0,
                    events.as_mut_ptr(),
                    events.len() as i32,
                    std::ptr::null(),
                )
            };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(err);
            }
            for ev in &events[..n as usize] {
                let token = ev.udata as usize as u64;
                let index = (token & INDEX_MASK) as u32;
                let writable = ev.filter == libc::EVFILT_WRITE;
                match token & !INDEX_MASK {
                    _ if token == TOKEN_LISTEN => self.accept(),
                    KIND_CONN if writable => self.flush_conn(index),
                    KIND_CONN => self.conn_readable(index),
                    KIND_PTY if writable => self.flush_input(index),
                    KIND_PTY => self.pty_readable(index),
                    KIND_PROC => self.child_exited(index, ev.ident as libc::pid_t),
                    _ => {}
                }
            }
        }
        Ok(())
    }

    fn accept(&mut self) {
        loop {
            // SAFETY: accept on our listening socket.
            let fd =
                unsafe { libc::accept(self.listen, std::ptr::null_mut(), std::ptr::null_mut()) };
            if fd < 0 {
                return;
            }
            if set_nonblock_cloexec(fd).is_err() {
                // SAFETY: closing a descriptor we just received.
                unsafe { libc::close(fd) };
                continue;
            }
            let id = self.next_conn;
            self.next_conn = self.next_conn.wrapping_add(1).max(1);
            let nosig: libc::c_int = 1;
            // SAFETY: setting SO_NOSIGPIPE with a valid option value.
            unsafe {
                libc::setsockopt(
                    fd,
                    libc::SOL_SOCKET,
                    libc::SO_NOSIGPIPE,
                    (&raw const nosig).cast(),
                    4,
                );
            }
            self.conns.insert(
                id,
                Conn {
                    fd,
                    inbuf: Vec::new(),
                    out: VecDeque::new(),
                    front_sent: 0,
                    queued: 0,
                    attached: None,
                    write_armed: false,
                    read_armed: true,
                    closing: false,
                },
            );
            let _ = self.kev(
                fd as usize,
                libc::EVFILT_READ,
                libc::EV_ADD,
                0,
                KIND_CONN | u64::from(id),
            );
        }
    }

    fn conn_readable(&mut self, id: u32) {
        let Some(conn) = self.conns.get_mut(&id) else { return };
        loop {
            // SAFETY: buf is valid for its length.
            let n = unsafe { libc::read(conn.fd, self.buf.as_mut_ptr().cast(), self.buf.len()) };
            if n > 0 {
                conn.inbuf.extend_from_slice(&self.buf[..n as usize]);
                continue;
            }
            if n == 0 || io::Error::last_os_error().kind() != io::ErrorKind::WouldBlock {
                conn.closing = true;
            }
            break;
        }
        let mut offset = 0;
        loop {
            let Some(conn) = self.conns.get_mut(&id) else { return };
            let frame = match proto::take_frame(&conn.inbuf[offset..]) {
                Ok(Some((kind, payload, used))) => Some((kind, payload.to_vec(), used)),
                Ok(None) => None,
                Err(_) => {
                    conn.closing = true;
                    None
                }
            };
            let Some((kind, payload, used)) = frame else { break };
            offset += used;
            self.request(id, kind, &payload);
        }
        let Some(conn) = self.conns.get_mut(&id) else { return };
        conn.inbuf.drain(..offset);
        if conn.closing {
            // EOF stays readable; stop listening so it cannot spin the loop.
            if conn.read_armed {
                conn.read_armed = false;
                let fd = conn.fd;
                let _ = self.kev(fd as usize, libc::EVFILT_READ, libc::EV_DELETE, 0, 0);
            }
            if self.conns.get(&id).is_some_and(|c| c.out.is_empty()) {
                self.drop_conn(id);
            }
        }
    }

    fn send(&mut self, id: u32, kind: u8, payload: &[u8]) {
        if let Some(conn) = self.conns.get_mut(&id) {
            let mut frame = Vec::with_capacity(payload.len() + 5);
            proto::put_frame(&mut frame, kind, payload);
            conn.queued += frame.len();
            conn.out.push_back(frame);
            self.flush_conn(id);
        }
    }

    fn flush_conn(&mut self, id: u32) {
        let Some(conn) = self.conns.get_mut(&id) else { return };
        let mut failed = false;
        while let Some(front) = conn.out.front() {
            let rest = &front[conn.front_sent..];
            // SAFETY: rest is a valid slice.
            let n = unsafe { libc::write(conn.fd, rest.as_ptr().cast(), rest.len()) };
            if n > 0 {
                let n = n as usize;
                conn.queued -= n;
                conn.front_sent += n;
                if conn.front_sent == front.len() {
                    conn.out.pop_front();
                    conn.front_sent = 0;
                }
                continue;
            }
            if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::WouldBlock {
                break;
            }
            failed = true;
            break;
        }
        if failed {
            conn.out.clear();
            conn.front_sent = 0;
            conn.queued = 0;
            conn.closing = true;
        }
        let want = !conn.out.is_empty();
        let (fd, armed) = (conn.fd, conn.write_armed);
        let done = conn.closing && !want;
        if want != armed {
            conn.write_armed = want;
            let flags = if want { libc::EV_ADD } else { libc::EV_DELETE };
            let _ = self.kev(fd as usize, libc::EVFILT_WRITE, flags, 0, KIND_CONN | u64::from(id));
        }
        if done {
            self.drop_conn(id);
        }
    }

    fn drop_conn(&mut self, id: u32) {
        let Some(conn) = self.conns.remove(&id) else { return };
        if let Some(t) = conn.attached.and_then(|t| self.terms.get_mut(&t)) {
            t.attached.retain(|c| *c != id);
        }
        for t in self.terms.values_mut() {
            t.waiters.retain(|c| *c != id);
        }
        // SAFETY: closing a descriptor we own; kqueue drops its filters.
        unsafe { libc::close(conn.fd) };
    }

    fn close_conn(&mut self, id: u32) {
        if let Some(conn) = self.conns.get_mut(&id) {
            conn.out.clear();
            conn.front_sent = 0;
            conn.queued = 0;
        }
        self.drop_conn(id);
    }

    fn err(&mut self, id: u32, msg: &str) {
        self.send(id, proto::ERR, msg.as_bytes());
    }

    /// Sends `t`'s current state to `c` as a SNAPSHOT. Closes the connection
    /// when no faithful snapshot can be made, so the client never has a gap.
    fn snapshot_to(&mut self, t: u32, c: u32) {
        let Some(term) = self.terms.get_mut(&t) else { return };
        flush_parse(term);
        let payload = term.vt.vt_replay_bytes().ok().map(|replay| {
            let mut p = Vec::with_capacity(replay.len() + 4);
            p.extend_from_slice(&term.cols.to_le_bytes());
            p.extend_from_slice(&term.rows.to_le_bytes());
            p.extend_from_slice(&replay);
            p
        });
        self.flush_replies(t);
        match payload {
            Some(p) => {
                if let Some(conn) = self.conns.get_mut(&c) {
                    conn.drop_unstarted();
                }
                self.send(c, proto::SNAPSHOT, &p);
            }
            None => self.close_conn(c),
        }
    }

    fn detach(&mut self, c: u32) {
        let Some(old) = self.conns.get_mut(&c).and_then(|conn| conn.attached.take()) else {
            return;
        };
        if let Some(term) = self.terms.get_mut(&old) {
            term.attached.retain(|x| *x != c);
        }
    }

    fn request(&mut self, id: u32, kind: u8, payload: &[u8]) {
        let mut r = Reader(payload);
        match kind {
            proto::CREATE => match self.create(payload) {
                Ok(t) => self.send(id, proto::OK, &t.to_le_bytes()),
                Err(e) => self.err(id, &format!("create failed: {e}")),
            },
            proto::WRITE => {
                let Some(t) = r.u32() else { return self.err(id, "bad write") };
                let rest = r.0;
                let attached = self.conns.get(&id).is_some_and(|c| c.attached == Some(t));
                match self.terms.get_mut(&t) {
                    Some(term) => {
                        if term.pty_open {
                            term.input.extend(rest);
                        }
                    }
                    None => return self.err(id, "no such terminal"),
                }
                self.flush_input(t);
                if !attached {
                    self.send(id, proto::OK, &[]);
                }
            }
            proto::SCREEN | proto::REPLAY => {
                let Some(t) = r.u32() else { return self.err(id, "bad request") };
                let Some(term) = self.terms.get_mut(&t) else {
                    return self.err(id, "no such terminal");
                };
                flush_parse(term);
                let out = if kind == proto::SCREEN {
                    term.vt.viewport_text().map(String::into_bytes)
                } else {
                    term.vt.vt_replay_bytes()
                };
                self.flush_replies(t);
                match out {
                    Ok(bytes) => self.send(id, proto::OK, &bytes),
                    Err(e) => self.err(id, &format!("read failed: {e}")),
                }
            }
            proto::LIST => {
                let mut ids: Vec<_> = self.terms.keys().copied().collect();
                ids.sort_unstable();
                let mut text = String::new();
                for t in ids {
                    let term = &self.terms[&t];
                    let state =
                        term.exit.map_or_else(|| "running".to_string(), |s| format!("exited {s}"));
                    text.push_str(&format!(
                        "{t}\t{}\t{}x{}\t{state}\n",
                        term.pid, term.cols, term.rows
                    ));
                }
                self.send(id, proto::OK, text.as_bytes());
            }
            proto::KILL => {
                let Some(t) = r.u32() else { return self.err(id, "bad kill") };
                if let Some(term) = self.terms.remove(&t) {
                    if term.exit.is_none() {
                        // SAFETY: signalling our own, not yet reaped child.
                        unsafe { libc::kill(term.pid, libc::SIGHUP) };
                    }
                    // SAFETY: closing the master hangs up the slave side.
                    unsafe { libc::close(term.master) };
                    for c in &term.attached {
                        if let Some(conn) = self.conns.get_mut(c) {
                            conn.attached = None;
                        }
                    }
                    for c in term.attached.iter().chain(&term.waiters) {
                        self.send(*c, proto::EXIT, &(-1i32).to_le_bytes());
                    }
                }
                self.send(id, proto::OK, &[]);
            }
            proto::WAIT => {
                let Some(t) = r.u32() else { return self.err(id, "bad wait") };
                match self.terms.get_mut(&t) {
                    Some(term) => match term.exit {
                        Some(s) => self.send(id, proto::EXIT, &s.to_le_bytes()),
                        None => term.waiters.push(id),
                    },
                    None => self.err(id, "no such terminal"),
                }
            }
            proto::ATTACH => {
                let Some(t) = r.u32() else { return self.err(id, "bad attach") };
                if !self.terms.contains_key(&t) {
                    return self.err(id, "no such terminal");
                }
                // One subscription per connection.
                self.detach(id);
                let Some(term) = self.terms.get_mut(&t) else { return };
                term.attached.push(id);
                let exit = term.exit;
                if let Some(c) = self.conns.get_mut(&id) {
                    c.attached = Some(t);
                }
                self.snapshot_to(t, id);
                if let Some(s) = exit {
                    self.send(id, proto::EXIT, &s.to_le_bytes());
                }
            }
            proto::RESIZE => {
                let (Some(t), Some(cols), Some(rows)) = (r.u32(), r.u16(), r.u16()) else {
                    return self.err(id, "bad resize");
                };
                let attached = self.conns.get(&id).is_some_and(|c| c.attached == Some(t));
                let Some(term) = self.terms.get_mut(&t) else {
                    return self.err(id, "no such terminal");
                };
                flush_parse(term);
                let (cols, rows) = (cols.max(1), rows.max(1));
                if (cols, rows) != (term.cols, term.rows) {
                    // Pixel sizes are unknown to the server; size reports
                    // in pixels answer 0, as with an unknown cell size.
                    let _ = term.vt.resize(cols, rows, 0, 0);
                    (term.cols, term.rows) = (cols, rows);
                    set_winsize(term.master, cols, rows);
                    // The resize may emit an in-band size report (mode 2048).
                    self.flush_replies(t);
                    // Every viewer must continue from the new geometry.
                    let viewers =
                        self.terms.get(&t).map(|x| x.attached.clone()).unwrap_or_default();
                    for c in viewers {
                        self.snapshot_to(t, c);
                    }
                }
                if !attached {
                    self.send(id, proto::OK, &[]);
                }
            }
            proto::STATS => {
                let pending: usize = self.terms.values().map(|t| t.pending.len()).sum();
                let bytes: u64 = self.terms.values().map(|t| t.bytes_in).sum();
                let text = format!(
                    "pid\t{}\nterminals\t{}\nclients\t{}\npending_bytes\t{pending}\nbytes_in\t{bytes}\n",
                    std::process::id(),
                    self.terms.len(),
                    self.conns.len()
                );
                self.send(id, proto::OK, text.as_bytes());
            }
            proto::UPGRADE => {
                // Returns only on failure: on success the process is the new binary.
                if let Err(e) = self.upgrade(id, payload) {
                    self.err(id, &format!("upgrade failed: {e}"));
                }
            }
            proto::SHUTDOWN => {
                self.send(id, proto::OK, &[]);
                self.shutdown = true;
            }
            _ => self.err(id, "unknown request"),
        }
    }

    /// Upgrade in place: write every terminal's state to a file, keep the
    /// PTY and listening descriptors open across exec, and exec the new
    /// binary with `--resume`. The pid stays the same, so programs remain
    /// our children and their exit codes are still ours to collect.
    fn upgrade(&mut self, requester: u32, payload: &[u8]) -> io::Result<()> {
        let exe = if payload.is_empty() {
            std::env::current_exe()?
        } else {
            std::path::PathBuf::from(OsStr::from_bytes(payload))
        };
        let mut state = b"MUX2S1".to_vec();
        state.extend_from_slice(&self.next_term.to_le_bytes());
        state.extend_from_slice(&self.listen.to_le_bytes());
        state.extend_from_slice(&u32::try_from(self.terms.len()).expect("fits").to_le_bytes());
        let ids: Vec<u32> = self.terms.keys().copied().collect();
        for &t in &ids {
            let term = self.terms.get_mut(&t).expect("listed");
            flush_parse(term);
            // A replay cut inside a long control string would not resume the
            // stream exactly; refuse rather than lose state.
            if !term.vt.vt_replay_resumes_stream() {
                return Err(io::Error::other(format!(
                    "terminal {t} is inside a long control sequence; retry"
                )));
            }
            let replay = term
                .vt
                .vt_replay_bytes()
                .map_err(|e| io::Error::other(format!("terminal {t}: {e}")))?;
            self.flush_replies(t);
            let term = &self.terms[&t];
            state.extend_from_slice(&t.to_le_bytes());
            state.extend_from_slice(&term.pid.to_le_bytes());
            state.extend_from_slice(&term.master.to_le_bytes());
            state.extend_from_slice(&term.cols.to_le_bytes());
            state.extend_from_slice(&term.rows.to_le_bytes());
            state.push(u8::from(term.exit.is_some()));
            state.extend_from_slice(&term.exit.unwrap_or(0).to_le_bytes());
            state.push(u8::from(term.pty_open));
            state.extend_from_slice(&term.bytes_in.to_le_bytes());
            let input: Vec<u8> = term.input.iter().copied().collect();
            proto::put_bytes(&mut state, &input);
            proto::put_bytes(&mut state, &replay);
        }
        let path = proto::socket_path().with_file_name(format!("state-{}", std::process::id()));
        {
            use std::io::Write as _;
            use std::os::unix::fs::OpenOptionsExt as _;
            let _ = std::fs::remove_file(&path);
            let mut f =
                std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path)?;
            f.write_all(&state)?;
            f.sync_all()?;
        }
        let keep: Vec<RawFd> =
            std::iter::once(self.listen).chain(self.terms.values().map(|t| t.master)).collect();
        for &fd in &keep {
            // SAFETY: clearing close-on-exec on descriptors we own.
            unsafe { libc::fcntl(fd, libc::F_SETFD, 0) };
        }
        // Tell the requester before the exec closes its connection.
        self.send(requester, proto::OK, &[]);
        if let Some(conn) = self.conns.get(&requester) {
            for frame in &conn.out {
                write_all_blocking(conn.fd, &frame[conn.front_sent.min(frame.len())..]);
            }
        }
        let cexe = CString::new(exe.as_os_str().as_bytes()).map_err(io::Error::other)?;
        let cflag = CString::new("--resume").expect("static");
        let cpath = CString::new(path.as_os_str().as_bytes()).map_err(io::Error::other)?;
        let argv = [cexe.as_ptr(), cflag.as_ptr(), cpath.as_ptr(), std::ptr::null()];
        // SAFETY: execv with a null-terminated argv of live CStrings. Client
        // sockets and the kqueue are close-on-exec.
        unsafe { libc::execv(cexe.as_ptr(), argv.as_ptr()) };
        let err = io::Error::last_os_error();
        for &fd in &keep {
            // SAFETY: restoring close-on-exec after the failed exec.
            unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
        }
        let _ = std::fs::remove_file(&path);
        Err(err)
    }

    /// Rebuilds the server from an upgrade state file.
    fn resume(&mut self, state: &[u8]) -> io::Result<()> {
        let bad = || io::Error::new(io::ErrorKind::InvalidData, "bad upgrade state");
        let rest = state.strip_prefix(b"MUX2S1").ok_or_else(bad)?;
        let mut r = Reader(rest);
        self.next_term = r.u32().ok_or_else(bad)?;
        let _listen = r.u32().ok_or_else(bad)?; // already adopted by main
        let count = r.u32().ok_or_else(bad)?;
        for _ in 0..count {
            let t = r.u32().ok_or_else(bad)?;
            let pid = r.u32().ok_or_else(bad)? as libc::pid_t;
            let master = r.u32().ok_or_else(bad)? as RawFd;
            let cols = r.u16().ok_or_else(bad)?;
            let rows = r.u16().ok_or_else(bad)?;
            let (exited, rest) = r.0.split_first().ok_or_else(bad)?;
            r.0 = rest;
            let code = r.u32().ok_or_else(bad)? as i32;
            let (open, rest) = r.0.split_first().ok_or_else(bad)?;
            r.0 = rest;
            let lo = u64::from(r.u32().ok_or_else(bad)?);
            let hi = u64::from(r.u32().ok_or_else(bad)?);
            let input = r.bytes().ok_or_else(bad)?.to_vec();
            let replay = r.bytes().ok_or_else(bad)?.to_vec();
            let replies = Arc::new(Mutex::new(Vec::new()));
            let sink = replies.clone();
            let callbacks = Callbacks {
                on_pty_write: Some(Box::new(move |bytes: &[u8]| {
                    sink.lock().expect("reply sink").extend_from_slice(bytes);
                })),
                ..Callbacks::default()
            };
            let mut vt = Terminal::new(cols, rows, SCROLLBACK_BYTES, callbacks)
                .map_err(|e| io::Error::other(format!("terminal: {e}")))?;
            vt.vt_write(&replay);
            // Restoring state is not program output: drop any reply it made.
            replies.lock().expect("reply sink").clear();
            set_nonblock_cloexec(master)?;
            self.terms.insert(
                t,
                Term {
                    pid,
                    master,
                    vt,
                    cols,
                    rows,
                    pending: Vec::new(),
                    replies,
                    input: input.into(),
                    input_armed: false,
                    attached: Vec::new(),
                    waiters: Vec::new(),
                    exit: (*exited != 0).then_some(code),
                    pty_open: *open != 0,
                    bytes_in: lo | (hi << 32),
                },
            );
            if *open != 0 {
                self.kev(
                    master as usize,
                    libc::EVFILT_READ,
                    libc::EV_ADD,
                    0,
                    KIND_PTY | u64::from(t),
                )?;
            }
            if *exited == 0 {
                if let Err(e) = self.kev(
                    pid as usize,
                    libc::EVFILT_PROC,
                    libc::EV_ADD | libc::EV_ONESHOT,
                    libc::NOTE_EXIT,
                    KIND_PROC | u64::from(t),
                ) {
                    if e.raw_os_error() == Some(libc::ESRCH) {
                        self.child_exited(t, pid);
                    } else {
                        return Err(e);
                    }
                }
            }
            self.flush_input(t);
        }
        Ok(())
    }

    fn create(&mut self, payload: &[u8]) -> io::Result<u32> {
        let bad = || io::Error::new(io::ErrorKind::InvalidInput, "bad create payload");
        let mut r = Reader(payload);
        let cols = r.u16().ok_or_else(bad)?.max(1);
        let rows = r.u16().ok_or_else(bad)?.max(1);
        let cwd = r.bytes().ok_or_else(bad)?.to_vec();
        let argc = r.u16().ok_or_else(bad)?;
        let mut argv = Vec::with_capacity(argc as usize);
        for _ in 0..argc {
            argv.push(CString::new(r.bytes().ok_or_else(bad)?).map_err(|_| bad())?);
        }
        if argv.is_empty() {
            let shell = std::env::var_os("SHELL").unwrap_or_else(|| "/bin/zsh".into());
            argv.push(CString::new(shell.as_bytes()).map_err(|_| bad())?);
            argv.push(CString::new("-l").expect("static"));
        }
        let cwd = if cwd.is_empty() { None } else { Some(CString::new(cwd).map_err(|_| bad())?) };

        let replies = Arc::new(Mutex::new(Vec::new()));
        let sink = replies.clone();
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new(move |bytes: &[u8]| {
                sink.lock().expect("reply sink").extend_from_slice(bytes);
            })),
            ..Callbacks::default()
        };
        let vt = Terminal::new(cols, rows, SCROLLBACK_BYTES, callbacks)
            .map_err(|e| io::Error::other(format!("terminal: {e}")))?;
        let (master, pid) = spawn_pty(&argv, cwd.as_deref(), cols, rows)?;

        let t = self.next_term;
        self.next_term = self.next_term.wrapping_add(1).max(1);
        self.terms.insert(
            t,
            Term {
                pid,
                master,
                vt,
                cols,
                rows,
                pending: Vec::new(),
                replies,
                input: VecDeque::new(),
                input_armed: false,
                attached: Vec::new(),
                waiters: Vec::new(),
                exit: None,
                pty_open: true,
                bytes_in: 0,
            },
        );
        self.kev(master as usize, libc::EVFILT_READ, libc::EV_ADD, 0, KIND_PTY | u64::from(t))?;
        if let Err(e) = self.kev(
            pid as usize,
            libc::EVFILT_PROC,
            libc::EV_ADD | libc::EV_ONESHOT,
            libc::NOTE_EXIT,
            KIND_PROC | u64::from(t),
        ) {
            // The child exited before the filter was added: reap it now.
            if e.raw_os_error() == Some(libc::ESRCH) {
                self.child_exited(t, pid);
            } else {
                return Err(e);
            }
        }
        Ok(t)
    }

    /// Moves parser replies to the program's input queue and writes it.
    fn flush_replies(&mut self, t: u32) {
        let Some(term) = self.terms.get_mut(&t) else { return };
        let replies = std::mem::take(&mut *term.replies.lock().expect("reply sink"));
        if !replies.is_empty() && term.pty_open {
            term.input.extend(replies);
        }
        self.flush_input(t);
    }

    /// Writes queued input without blocking; waits for EVFILT_WRITE when the
    /// PTY is full (a program that does not read its input stalls only its
    /// own terminal).
    fn flush_input(&mut self, t: u32) {
        let Some(term) = self.terms.get_mut(&t) else { return };
        while !term.input.is_empty() && term.pty_open {
            let (front, _) = term.input.as_slices();
            // SAFETY: front is a valid slice.
            let n = unsafe { libc::write(term.master, front.as_ptr().cast(), front.len()) };
            if n > 0 {
                term.input.drain(..n as usize);
                continue;
            }
            if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::WouldBlock {
                break;
            }
            term.input.clear();
            break;
        }
        let want = !term.input.is_empty() && term.pty_open;
        if want != term.input_armed {
            term.input_armed = want;
            let (fd, flags) = (term.master, if want { libc::EV_ADD } else { libc::EV_DELETE });
            let _ = self.kev(fd as usize, libc::EVFILT_WRITE, flags, 0, KIND_PTY | u64::from(t));
        }
    }

    /// Reads up to `budget` bytes of PTY output for `t`. Returns true at EOF.
    fn read_pty(&mut self, t: u32, budget: usize) -> bool {
        let Some(term) = self.terms.get_mut(&t) else { return true };
        let watched = !term.attached.is_empty();
        let mut forwarded: Vec<u8> = Vec::new();
        let mut eof = false;
        let mut total = 0;
        while total < budget {
            // SAFETY: buf is valid for its length.
            let n =
                unsafe { libc::read(term.master, self.buf.as_mut_ptr().cast(), self.buf.len()) };
            if n > 0 {
                let chunk = &self.buf[..n as usize];
                total += chunk.len();
                term.bytes_in += chunk.len() as u64;
                // Mid-sequence bytes complete whatever the last parse left
                // open, possibly a query: never defer them.
                if watched || !term.vt.vt_stream_is_ground() || needs_immediate_parse(chunk) {
                    flush_parse(term);
                    let accepted = term.vt.vt_write_with_normalized(chunk);
                    if watched {
                        forwarded.extend_from_slice(&accepted);
                    }
                } else {
                    term.pending.extend_from_slice(chunk);
                    if term.pending.len() >= PARSE_BATCH {
                        flush_parse(term);
                    }
                }
                continue;
            }
            if n == 0 || io::Error::last_os_error().kind() != io::ErrorKind::WouldBlock {
                eof = true;
            }
            break;
        }
        let master = term.master;
        let clients = if forwarded.is_empty() { Vec::new() } else { term.attached.clone() };
        let close = eof && term.pty_open;
        if close {
            term.pty_open = false;
            term.input.clear();
        }
        self.flush_replies(t);
        if close {
            let _ = self.kev(master as usize, libc::EVFILT_READ, libc::EV_DELETE, 0, 0);
        }
        if !clients.is_empty() {
            self.fanout(t, &clients, &forwarded);
        }
        eof
    }

    fn pty_readable(&mut self, t: u32) {
        self.read_pty(t, READ_BUDGET);
    }

    fn fanout(&mut self, t: u32, clients: &[u32], bytes: &[u8]) {
        for &c in clients {
            let behind = self.conns.get(&c).map_or(0, |conn| conn.queued);
            if behind > CLIENT_BACKLOG_MAX {
                // The snapshot holds every byte parsed so far, including
                // these, so it replaces the unsent backlog exactly.
                self.snapshot_to(t, c);
            } else {
                self.send(c, proto::OUTPUT, bytes);
            }
        }
    }

    fn child_exited(&mut self, t: u32, pid: libc::pid_t) {
        let mut status = 0;
        // SAFETY: reaping our own child; NOTE_EXIT means it has exited.
        let r = unsafe { libc::waitpid(pid, &mut status, 0) };
        let code = if r == pid {
            if libc::WIFEXITED(status) {
                libc::WEXITSTATUS(status)
            } else {
                128 + libc::WTERMSIG(status)
            }
        } else {
            -1
        };
        // A killed terminal is gone already; the wait above reaped its child.
        if !self.terms.contains_key(&t) {
            return;
        }
        // Output written before exit is still in the PTY: read all of it, so
        // the screen a waiter reads includes it.
        self.read_pty(t, EXIT_DRAIN_MAX);
        let Some(term) = self.terms.get_mut(&t) else { return };
        flush_parse(term);
        term.exit = Some(code);
        let notify: Vec<u32> =
            term.waiters.drain(..).chain(term.attached.iter().copied()).collect();
        self.flush_replies(t);
        for c in notify {
            self.send(c, proto::EXIT, &code.to_le_bytes());
        }
    }
}

fn flush_parse(term: &mut Term) {
    if !term.pending.is_empty() {
        let pending = std::mem::take(&mut term.pending);
        term.vt.vt_write(&pending);
        term.pending = pending;
        term.pending.clear();
    }
}

/// Writes all of `data` to a socket, waiting for room. Only used right
/// before exec, when nothing else needs the loop.
fn write_all_blocking(fd: RawFd, mut data: &[u8]) {
    while !data.is_empty() {
        // SAFETY: data is a valid slice.
        let n = unsafe { libc::write(fd, data.as_ptr().cast(), data.len()) };
        if n > 0 {
            data = &data[n as usize..];
        } else if n < 0 && io::Error::last_os_error().kind() == io::ErrorKind::WouldBlock {
            let mut pfd = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            // SAFETY: one valid pollfd.
            unsafe { libc::poll(&mut pfd, 1, 1000) };
        } else {
            return;
        }
    }
}

fn set_winsize(fd: RawFd, cols: u16, rows: u16) {
    let ws = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: TIOCSWINSZ with a valid winsize.
    unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws) };
}

// From <spawn.h> (macOS 10.15+); not bound by the pinned libc.
const POSIX_SPAWN_SETSID: libc::c_short = 0x0400;
unsafe extern "C" {
    fn posix_spawn_file_actions_addchdir_np(
        actions: *mut libc::posix_spawn_file_actions_t,
        path: *const libc::c_char,
    ) -> libc::c_int;
}

/// Opens a PTY and starts `argv` on it as a session leader with the PTY as
/// its controlling terminal.
///
/// posix_spawn, not fork: its cost does not grow with the server's memory.
/// POSIX_SPAWN_SETSID makes the child a session leader, and on macOS a
/// session leader without a controlling terminal acquires the tty it opens
/// first, so opening the slave by path as fd 0 sets the controlling terminal
/// (checked by `mux2-ctty-probe`: tty, foreground process group and job
/// control all hold). The child starts with default signal dispositions, an
/// empty signal mask, and only fds 0-2 (POSIX_SPAWN_CLOEXEC_DEFAULT).
fn spawn_pty(
    argv: &[CString],
    cwd: Option<&std::ffi::CStr>,
    cols: u16,
    rows: u16,
) -> io::Result<(RawFd, libc::pid_t)> {
    // SAFETY: standard PTY allocation on a fresh master descriptor.
    let master = cvt(unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY) })?;
    let close_master = |e: io::Error| {
        // SAFETY: closing the master we own.
        unsafe { libc::close(master) };
        e
    };
    let mut name = [0 as libc::c_char; 128];
    // SAFETY: grantpt/unlockpt on our master; TIOCPTYGNAME fills 128 bytes.
    unsafe {
        cvt(libc::grantpt(master)).map_err(close_master)?;
        cvt(libc::unlockpt(master)).map_err(close_master)?;
        cvt(libc::ioctl(master, libc::TIOCPTYGNAME as _, name.as_mut_ptr()))
            .map_err(close_master)?;
    }
    set_nonblock_cloexec(master).map_err(close_master)?;
    set_winsize(master, cols, rows);
    let mut ptrs: Vec<*mut libc::c_char> = argv.iter().map(|a| a.as_ptr().cast_mut()).collect();
    ptrs.push(std::ptr::null_mut());
    let mut pid: libc::pid_t = 0;
    // SAFETY: attribute and file-action objects are initialized before use
    // and destroyed after; every pointer passed outlives the call.
    let rc = unsafe {
        let mut attr: libc::posix_spawnattr_t = std::ptr::null_mut();
        let mut fa: libc::posix_spawn_file_actions_t = std::ptr::null_mut();
        libc::posix_spawnattr_init(&mut attr);
        libc::posix_spawn_file_actions_init(&mut fa);
        let mut all: libc::sigset_t = 0;
        libc::sigfillset(&mut all);
        let mut none: libc::sigset_t = 0;
        libc::sigemptyset(&mut none);
        libc::posix_spawnattr_setsigdefault(&mut attr, &all);
        libc::posix_spawnattr_setsigmask(&mut attr, &none);
        let flags = POSIX_SPAWN_SETSID
            | libc::POSIX_SPAWN_SETSIGDEF as libc::c_short
            | libc::POSIX_SPAWN_SETSIGMASK as libc::c_short
            | libc::POSIX_SPAWN_CLOEXEC_DEFAULT as libc::c_short;
        libc::posix_spawnattr_setflags(&mut attr, flags);
        libc::posix_spawn_file_actions_addopen(&mut fa, 0, name.as_ptr(), libc::O_RDWR, 0);
        libc::posix_spawn_file_actions_adddup2(&mut fa, 0, 1);
        libc::posix_spawn_file_actions_adddup2(&mut fa, 0, 2);
        if let Some(dir) = cwd {
            posix_spawn_file_actions_addchdir_np(&mut fa, dir.as_ptr());
        }
        let rc = libc::posix_spawnp(&mut pid, ptrs[0], &fa, &attr, ptrs.as_ptr(), environ_ptr());
        libc::posix_spawn_file_actions_destroy(&mut fa);
        libc::posix_spawnattr_destroy(&mut attr);
        rc
    };
    if rc != 0 {
        return Err(close_master(io::Error::from_raw_os_error(rc)));
    }
    Ok((master, pid))
}

/// The current environment, for posix_spawn.
fn environ_ptr() -> *const *mut libc::c_char {
    unsafe extern "C" {
        fn _NSGetEnviron() -> *mut *const *mut libc::c_char;
    }
    // SAFETY: _NSGetEnviron returns the process environment pointer.
    unsafe { *_NSGetEnviron() }
}

fn listen_socket(path: &std::path::Path) -> io::Result<RawFd> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
        let cdir = CString::new(dir.as_os_str().as_bytes()).map_err(io::Error::other)?;
        // SAFETY: chmod on a directory we own.
        unsafe { libc::chmod(cdir.as_ptr(), 0o700) };
    }
    let _ = std::fs::remove_file(path);
    // SAFETY: plain socket/bind/listen with a correctly built sockaddr_un.
    unsafe {
        let fd = cvt(libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0))?;
        let mut addr: libc::sockaddr_un = std::mem::zeroed();
        addr.sun_family = libc::AF_UNIX as _;
        let bytes = path.as_os_str().as_bytes();
        if bytes.len() >= addr.sun_path.len() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "socket path too long"));
        }
        for (dst, src) in addr.sun_path.iter_mut().zip(bytes) {
            *dst = *src as libc::c_char;
        }
        cvt(libc::bind(fd, (&raw const addr).cast(), size_of::<libc::sockaddr_un>() as u32))?;
        cvt(libc::listen(fd, 1024))?;
        set_nonblock_cloexec(fd)?;
        Ok(fd)
    }
}

fn raise_nofile() {
    // SAFETY: get/setrlimit with a valid struct.
    unsafe {
        let mut lim: libc::rlimit = std::mem::zeroed();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) == 0 {
            let mut max: libc::c_int = 0;
            let mut len = size_of::<libc::c_int>();
            let name = c"kern.maxfilesperproc";
            libc::sysctlbyname(
                name.as_ptr(),
                (&raw mut max).cast(),
                &mut len,
                std::ptr::null_mut(),
                0,
            );
            let want = if max > 0 { (max as libc::rlim_t).min(lim.rlim_max) } else { lim.rlim_max };
            lim.rlim_cur = want;
            libc::setrlimit(libc::RLIMIT_NOFILE, &lim);
        }
    }
}

fn main() {
    let path = proto::socket_path();
    raise_nofile();
    let ready_fd =
        std::env::var_os("MUX2_READY_FD").and_then(|v| OsStr::to_str(&v)?.parse::<RawFd>().ok());
    // SAFETY: single-threaded at this point.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        // Exit codes need waitpid: an inherited SIG_IGN would auto-reap.
        libc::signal(libc::SIGCHLD, libc::SIG_DFL);
        std::env::remove_var("MUX2_READY_FD");
        if std::env::var_os("TERM").is_none() {
            std::env::set_var("TERM", "xterm-256color");
        }
    }
    let args: Vec<std::ffi::OsString> = std::env::args_os().collect();
    let resume = (args.get(1).map(|a| a.as_bytes()) == Some(b"--resume"))
        .then(|| args.get(2).cloned())
        .flatten();
    let resume_state = resume.map(|p| {
        let state = std::fs::read(&p).unwrap_or_else(|e| {
            eprintln!("mux2d: cannot read upgrade state: {e}");
            std::process::exit(1);
        });
        let _ = std::fs::remove_file(&p);
        state
    });
    let listen = match &resume_state {
        // The listening socket survived the exec; its number is in the state.
        Some(state) if state.len() >= 14 && state.starts_with(b"MUX2S1") => {
            let fd = RawFd::from_le_bytes(state[10..14].try_into().expect("4 bytes"));
            set_nonblock_cloexec(fd).unwrap_or_else(|e| {
                eprintln!("mux2d: inherited listener: {e}");
                std::process::exit(1);
            });
            fd
        }
        Some(_) => {
            eprintln!("mux2d: bad upgrade state");
            std::process::exit(1);
        }
        None => match listen_socket(&path) {
            Ok(fd) => fd,
            Err(e) => {
                eprintln!("mux2d: cannot listen on {}: {e}", path.display());
                std::process::exit(1);
            }
        },
    };
    // SAFETY: kqueue has no preconditions.
    let kq = unsafe { libc::kqueue() };
    // SAFETY: marking our kqueue close-on-exec, so an upgrade starts clean.
    unsafe { libc::fcntl(kq, libc::F_SETFD, libc::FD_CLOEXEC) };
    let mut server = Server {
        kq,
        listen,
        terms: HashMap::new(),
        conns: HashMap::new(),
        next_term: 1,
        next_conn: 1,
        buf: vec![0; READ_CHUNK],
        shutdown: false,
    };
    server
        .kev(listen as usize, libc::EVFILT_READ, libc::EV_ADD, 0, TOKEN_LISTEN)
        .expect("register listener");
    if let Some(state) = &resume_state {
        if let Err(e) = server.resume(state) {
            eprintln!("mux2d: resume failed: {e}");
            std::process::exit(1);
        }
    }
    // Readiness: the client that started us waits on this descriptor.
    if let Some(fd) = ready_fd {
        // SAFETY: writing one byte to the inherited pipe, then closing it.
        unsafe {
            libc::write(fd, b"r".as_ptr().cast(), 1);
            libc::close(fd);
        }
    }
    if let Err(e) = server.run() {
        eprintln!("mux2d: {e}");
    }
    for term in server.terms.values() {
        if term.exit.is_none() {
            // SAFETY: hanging up our own, not yet reaped children.
            unsafe { libc::kill(term.pid, libc::SIGHUP) };
        }
    }
    let _ = std::fs::remove_file(&path);
}
