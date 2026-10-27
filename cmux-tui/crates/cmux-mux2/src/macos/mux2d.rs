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
use std::sync::{Arc, Mutex, PoisonError};

use cmux_mux2::{self as proto, Reader};
use ghostty_vt::{Callbacks, Terminal};

#[path = "mux2d_os.rs"]
mod os;
#[path = "mux2d_parse.rs"]
mod parse;
#[path = "mux2d_scan.rs"]
mod scan;
#[path = "mux2d_state.rs"]
mod state;

use os::*;
use parse::*;
use scan::{incomplete_tail_start, needs_immediate_parse};
use state::{parse_state, state_listener};

const READ_CHUNK: usize = 64 << 10;
/// Most PTY bytes read for one terminal per event, so one busy terminal
/// cannot starve the others (kqueue is level-triggered and fires again).
const READ_BUDGET: usize = 1 << 20;
/// Unwatched output is parsed in batches of this size (MUX2_PARSE_BATCH).
const PARSE_BATCH: usize = 256 << 10;
/// Batches one terminal may have at its parse worker. At the limit the
/// loop stops reading that PTY, so a flooding program waits in the kernel
/// and a query behind the backlog waits for at most this many batches.
const INFLIGHT_MAX: usize = 2;
/// Reads retried after EAGAIN while output is flowing (MUX2_READ_SPINS).
/// The macOS PTY buffer is small: a writer that refills it within a few
/// microseconds is read without a kevent round trip and a context switch.
const READ_SPINS: u32 = 32;

fn tunable(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// The first `n` bytes of `buf`, where `n` is what `read(2)` returned for it.
fn filled(buf: &[u8], n: isize) -> &[u8] {
    usize::try_from(n).ok().and_then(|n| buf.get(..n)).unwrap_or_default()
}
/// An attached client further behind than this is resynced with a snapshot.
const CLIENT_BACKLOG_MAX: usize = 16 << 20;
const SCROLLBACK_BYTES: usize = 10_000_000;
/// Output a dead child's descendants may still write before EXIT is sent.
const EXIT_DRAIN_MAX: usize = 16 << 20;

const TOKEN_LISTEN: u64 = 0;
const KIND_CONN: u64 = 1 << 32;
const KIND_PTY: u64 = 2 << 32;
const KIND_PROC: u64 = 3 << 32;
/// EVFILT_USER, ident = terminal id: a worker finished one of its batches.
const KIND_WAKE: u64 = 4 << 32;
const INDEX_MASK: u64 = 0xffff_ffff;

struct Term {
    pid: libc::pid_t,
    master: RawFd,
    /// The parser. Unwatched batches may be parsed on a worker thread; every
    /// other access goes through [`Term::vt`], which first waits for them.
    parser: Arc<Mutex<Terminal>>,
    /// Batches handed to a worker and not parsed yet.
    inflight: Arc<Inflight>,
    /// Whether the last chunk parsed here left a sequence open (a later chunk
    /// may complete a query). Deferred chunks never do, by construction of
    /// `needs_immediate_parse`, so this needs no worker round trip.
    open_seq: bool,
    cols: u16,
    rows: u16,
    /// PTY bytes not yet given to the parser.
    pending: Vec<u8>,
    /// An unfinished `ESC [ ...` (or lone ESC) at the end of the last
    /// unwatched read, prepended to the next read so the batch decision
    /// sees whole sequences. Parsed, in order, before any state access.
    carry: Vec<u8>,
    /// PTY reads stopped because INFLIGHT_MAX batches are at the worker.
    read_paused: bool,
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
            let keep = index < started
                || !matches!(frame.get(4), Some(&(proto::OUTPUT | proto::SNAPSHOT)));
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
    parse_batch: usize,
    read_spins: u32,
    /// Children of killed terminals not reaped yet; kept across upgrades.
    orphans: Vec<libc::pid_t>,
    /// Batches one terminal may have at its worker (MUX2_INFLIGHT_MAX).
    inflight_max: usize,
    /// Parse workers for unwatched batches (MUX2_PARSE_WORKERS, 0 = inline).
    workers: Vec<std::sync::mpsc::Sender<ParseJob>>,
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
            for ev in events.iter().take(n as usize) {
                let token = ev.udata as usize as u64;
                let index = (token & INDEX_MASK) as u32;
                let writable = ev.filter == libc::EVFILT_WRITE;
                if ev.filter == libc::EVFILT_USER {
                    // Routed by filter and ident, not by udata.
                    self.batch_done(ev.ident as u32);
                    continue;
                }
                match token & !INDEX_MASK {
                    _ if token == TOKEN_LISTEN => self.accept(),
                    KIND_CONN if writable => self.flush_conn(index),
                    KIND_CONN => self.conn_readable(index),
                    KIND_PTY if writable => self.flush_input(index),
                    KIND_PTY => self.pty_readable(index),
                    KIND_PROC => self.child_exited(index, ev.ident as libc::pid_t),
                    KIND_WAKE => self.batch_done(index),
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
                conn.inbuf.extend_from_slice(filled(&self.buf, n));
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
            let frame = match proto::take_frame(conn.inbuf.get(offset..).unwrap_or_default()) {
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
        let mut frame = Vec::with_capacity(payload.len() + 5);
        if let Err(e) = proto::put_frame(&mut frame, kind, payload) {
            // Over MAX_FRAME: the client's read_frame would refuse it and drop the link.
            eprintln!("mux2d: client {id}: kind {kind} frame of {} bytes: {e}", payload.len());
            self.drop_conn(id);
            return;
        }
        if let Some(conn) = self.conns.get_mut(&id) {
            conn.queued += frame.len();
            conn.out.push_back(frame);
            self.flush_conn(id);
        }
    }

    fn flush_conn(&mut self, id: u32) {
        let Some(conn) = self.conns.get_mut(&id) else { return };
        let mut failed = false;
        while let Some(front) = conn.out.front() {
            // An empty rest (never: a sent frame is popped) writes 0 and fails the link.
            let rest = front.get(conn.front_sent..).unwrap_or_default();
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
        let payload = term.vt().vt_replay_bytes().ok().map(|replay| {
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
                    term.vt().viewport_text().map(String::into_bytes)
                } else {
                    term.vt().vt_replay_bytes()
                };
                self.flush_replies(t);
                match out {
                    Ok(bytes) => self.send(id, proto::OK, &bytes),
                    Err(e) => self.err(id, &format!("read failed: {e}")),
                }
            }
            proto::LIST => {
                let mut terms: Vec<_> = self.terms.iter().collect();
                terms.sort_unstable_by_key(|(t, _)| **t);
                let mut text = String::new();
                for (t, term) in terms {
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
                        self.orphans.push(term.pid);
                    }
                    // SAFETY: closing the master hangs up the slave side.
                    unsafe { libc::close(term.master) };
                    let _ = self.kev(t as usize, libc::EVFILT_USER, libc::EV_DELETE, 0, 0);
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
                    // The grid and the PTY change together or not at all.
                    if term.vt().resize(cols, rows, 0, 0).is_err() {
                        return self.err(id, "resize failed");
                    }
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
                let pending: usize =
                    self.terms.values().map(|t| t.pending.len() + t.carry.len()).sum();
                let inflight: usize = self
                    .terms
                    .values()
                    .map(|t| *t.inflight.count.lock().unwrap_or_else(PoisonError::into_inner))
                    .sum();
                let bytes: u64 = self.terms.values().map(|t| t.bytes_in).sum();
                let text = format!(
                    "pid\t{}\nterminals\t{}\nclients\t{}\npending_bytes\t{pending}\ninflight_batches\t{inflight}\nbytes_in\t{bytes}\n",
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
            argv.push(c"-l".to_owned());
        }
        let cwd = if cwd.is_empty() { None } else { Some(CString::new(cwd).map_err(|_| bad())?) };

        let replies = Arc::new(Mutex::new(Vec::new()));
        let sink = replies.clone();
        let callbacks = Callbacks {
            on_pty_write: Some(Box::new(move |bytes: &[u8]| {
                sink.lock().unwrap_or_else(PoisonError::into_inner).extend_from_slice(bytes);
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
                parser: Arc::new(Mutex::new(vt)),
                inflight: Arc::default(),
                open_seq: false,
                carry: Vec::new(),
                read_paused: false,
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
        self.kev(
            t as usize,
            libc::EVFILT_USER,
            libc::EV_ADD | libc::EV_CLEAR,
            0,
            KIND_WAKE | u64::from(t),
        )?;
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
        let replies =
            std::mem::take(&mut *term.replies.lock().unwrap_or_else(PoisonError::into_inner));
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
    /// `may_pause` is false while draining after exit: every byte must be
    /// read before EXIT is sent.
    fn read_pty(&mut self, t: u32, budget: usize, may_pause: bool) -> bool {
        let Some(term) = self.terms.get_mut(&t) else { return true };
        let watched = !term.attached.is_empty();
        let mut forwarded: Vec<u8> = Vec::new();
        let mut eof = false;
        let mut total = 0;
        let mut spins = 0;
        // Set once the program has asked something: it is now waiting for
        // the answer, not writing, so spinning for more output only delays.
        let mut asked = false;
        let mut pause = false;
        let (parse_batch, read_spins, inflight_max) =
            (self.parse_batch, self.read_spins, self.inflight_max);
        while total < budget {
            // SAFETY: buf is valid for its length.
            let n =
                unsafe { libc::read(term.master, self.buf.as_mut_ptr().cast(), self.buf.len()) };
            if n > 0 {
                let read = filled(&self.buf, n);
                total += read.len();
                term.bytes_in += read.len() as u64;
                let joined;
                let data: &[u8] = if term.carry.is_empty() {
                    read
                } else {
                    term.carry.extend_from_slice(read);
                    joined = std::mem::take(&mut term.carry);
                    &joined
                };
                let (chunk, tail) = if watched {
                    (data, &[][..])
                } else {
                    data.split_at(incomplete_tail_start(data))
                };
                // Mid-sequence bytes complete whatever the last parse left
                // open, possibly a query: never defer them.
                if chunk.is_empty() {
                } else if watched || term.open_seq || needs_immediate_parse(chunk) {
                    flush_parse(term);
                    let mut vt = term.vt();
                    let accepted = vt.vt_write_with_normalized(chunk);
                    let open = !vt.vt_stream_is_ground();
                    drop(vt);
                    term.open_seq = open;
                    if watched {
                        forwarded.extend_from_slice(&accepted);
                    }
                    // A program that asked something waits for the answer:
                    // write it now, and stop spinning for more output.
                    let replies = std::mem::take(
                        &mut *term.replies.lock().unwrap_or_else(PoisonError::into_inner),
                    );
                    if !replies.is_empty() {
                        term.input.extend(replies);
                        write_input_now(term);
                        asked = true;
                    }
                } else {
                    term.pending.extend_from_slice(chunk);
                    if term.pending.len() >= parse_batch {
                        let worker = (t as usize)
                            .checked_rem(self.workers.len())
                            .and_then(|i| self.workers.get(i));
                        offload_parse(term, worker, self.kq, t);
                        if may_pause
                            && *term.inflight.count.lock().unwrap_or_else(PoisonError::into_inner)
                                >= inflight_max
                        {
                            term.read_paused = true;
                            pause = true;
                        }
                    }
                }
                term.carry.extend_from_slice(tail);
                if pause {
                    // Resumed by batch_done when the worker catches up.
                    break;
                }
                spins = 0;
                continue;
            }
            if n == 0 || io::Error::last_os_error().kind() != io::ErrorKind::WouldBlock {
                eof = true;
            } else if total > 0 && spins < read_spins && !asked {
                spins += 1;
                std::hint::spin_loop();
                continue;
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
        } else if pause {
            let token = KIND_PTY | u64::from(t);
            let _ = self.kev(master as usize, libc::EVFILT_READ, libc::EV_DISABLE, 0, token);
        }
        if !clients.is_empty() {
            self.fanout(t, &clients, &forwarded);
        }
        eof
    }

    fn pty_readable(&mut self, t: u32) {
        self.read_pty(t, READ_BUDGET, true);
    }

    /// A worker finished a batch of `t`: write any reply it produced, and
    /// resume reading the PTY if it was paused at INFLIGHT_MAX.
    fn batch_done(&mut self, t: u32) {
        self.flush_replies(t);
        let Some(term) = self.terms.get_mut(&t) else { return };
        let below =
            *term.inflight.count.lock().unwrap_or_else(PoisonError::into_inner) < self.inflight_max;
        if term.read_paused && below && term.pty_open {
            term.read_paused = false;
            let master = term.master;
            let token = KIND_PTY | u64::from(t);
            let _ = self.kev(master as usize, libc::EVFILT_READ, libc::EV_ENABLE, 0, token);
        }
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
            self.orphans.retain(|p| *p != pid);
            return;
        }
        // Output written before exit is still in the PTY: read all of it, so
        // the screen a waiter reads includes it.
        self.read_pty(t, EXIT_DRAIN_MAX, false);
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

pub fn main() {
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
    if args.get(1).map(|a| a.as_bytes()) == Some(b"--verify-state") {
        // Dry run for an upgrade: read the state the old server wrote and
        // rebuild every terminal, touching no descriptor.
        let ok = args
            .get(2)
            .and_then(|p| std::fs::read(p).ok())
            .is_some_and(|st| parse_state(&st).is_ok());
        std::process::exit(if ok { 0 } else { 1 });
    }
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
        Some(state) => {
            let Some(fd) = state_listener(state) else {
                eprintln!("mux2d: bad upgrade state");
                std::process::exit(1);
            };
            set_nonblock_cloexec(fd).unwrap_or_else(|e| {
                eprintln!("mux2d: inherited listener: {e}");
                std::process::exit(1);
            });
            fd
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
        parse_batch: tunable("MUX2_PARSE_BATCH", PARSE_BATCH),
        read_spins: tunable("MUX2_READ_SPINS", READ_SPINS as usize) as u32,
        orphans: Vec::new(),
        workers: spawn_parse_workers(),
        inflight_max: tunable("MUX2_INFLIGHT_MAX", INFLIGHT_MAX).max(1),
    };
    if let Err(e) = server.kev(listen as usize, libc::EVFILT_READ, libc::EV_ADD, 0, TOKEN_LISTEN) {
        eprintln!("mux2d: cannot register the listener: {e}");
        std::process::exit(1);
    }
    if let Some(state) = &resume_state
        && let Err(e) = server.resume(state)
    {
        eprintln!("mux2d: resume failed: {e}");
        std::process::exit(1);
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
