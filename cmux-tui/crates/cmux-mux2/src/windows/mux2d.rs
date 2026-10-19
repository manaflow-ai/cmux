//! `mux2d` on Windows: one process, one event-loop thread, one IO
//! completion port for every terminal and client. The Unix server's rules
//! hold unchanged (see `src/unix/mux2d.rs` and GOAL.md):
//! - every byte conhost writes reaches the VT parser, in order; unwatched
//!   output is parsed in batches (on parse workers), flushed before any read
//!   or change of terminal state and at once for a query;
//! - a viewer gets a snapshot, then exactly the stream the parser accepted;
//!   a viewer too far behind, or a resize, gets a fresh snapshot;
//! - nothing blocks the loop: pipe and socket IO is overlapped.
//!
//! What differs: the loop waits on completions, not readiness. Every PTY
//! pipe and client socket is a [`Slot`] with one read and one write in
//! flight; an operation that finishes at once is handled inline, so a busy
//! pipe is drained without a port round trip. Child exit comes from a
//! thread-pool wait that posts to the port. A terminal's EXIT is sent only
//! after its output pipe reports end of file, which conhost does after the
//! pseudoconsole is closed and its last frame written: the screen a waiter
//! reads holds every byte.
//!
//! Not on Windows: in-place upgrade (UPGRADE answers an error), live resize
//! following the viewer's console in `mux2 attach`.

use std::collections::{HashMap, VecDeque};
use std::ffi::OsString;
use std::io;
use std::os::windows::ffi::OsStringExt;
use std::os::windows::io::IntoRawSocket;
use std::sync::{Arc, Mutex};

use cmux_mux2::{self as proto, Reader};
use ghostty_vt::{Callbacks, Terminal};
use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::System::Console::HPCON;
use windows_sys::Win32::System::IO::OVERLAPPED_ENTRY;
use windows_sys::Win32::System::Threading::GetExitCodeProcess;

#[path = "mux2d_conpty.rs"]
mod conpty;
#[path = "mux2d_iocp.rs"]
mod iocp;
#[path = "../shared/mux2d_parse.rs"]
mod parse;
#[path = "../shared/mux2d_scan.rs"]
mod scan;

use iocp::{Done, Read, Slot, Waker};
use parse::*;
use scan::{incomplete_tail_start, needs_immediate_parse};

/// Most PTY bytes read for one terminal per turn, so one busy terminal
/// cannot starve the others; the rest is read on its next turn.
const READ_BUDGET: usize = 1 << 20;
const PARSE_BATCH: usize = 256 << 10;
const INFLIGHT_MAX: usize = 2;
const CLIENT_BACKLOG_MAX: usize = 16 << 20;
const SCROLLBACK_BYTES: usize = 10_000_000;

const INDEX_MASK: u64 = 0xffff_ffff;
const KIND_ACCEPT: u64 = 1 << 32;
const KIND_CONN: u64 = 2 << 32;
const KIND_PTY_OUT: u64 = 3 << 32;
const KIND_PTY_IN: u64 = 4 << 32;
const KIND_EXIT: u64 = 5 << 32;
pub(crate) const KIND_WAKE: u64 = 6 << 32;
/// A terminal whose read budget ran out: read it again after this turn.
const KIND_RESUME: u64 = 7 << 32;

fn tunable(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

struct Term {
    pid: u32,
    hpc: Option<HPCON>,
    out: Box<Slot>,
    input_slot: Box<Slot>,
    process: HANDLE,
    job: HANDLE,
    wait: HANDLE,
    parser: Arc<Mutex<Terminal>>,
    inflight: Arc<Inflight>,
    open_seq: bool,
    cols: u16,
    rows: u16,
    pending: Vec<u8>,
    carry: Vec<u8>,
    read_paused: bool,
    replies: Arc<Mutex<Vec<u8>>>,
    input: VecDeque<u8>,
    attached: Vec<u32>,
    waiters: Vec<u32>,
    /// The program's exit code, once known; EXIT is sent when the output
    /// pipe has also ended (`exit` is set then).
    code: Option<i32>,
    exit: Option<i32>,
    pty_open: bool,
    bytes_in: u64,
    /// MUX2_TAP_DIR: every byte read from conhost, for the verify gate.
    tap: Option<std::fs::File>,
}

struct Conn {
    slot: Box<Slot>,
    inbuf: Vec<u8>,
    out: VecDeque<Vec<u8>>,
    front_sent: usize,
    queued: usize,
    attached: Option<u32>,
    closing: bool,
}

impl Conn {
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
    waker: Waker,
    terms: HashMap<u32, Term>,
    conns: HashMap<u32, Conn>,
    /// Closed slots whose cancelled operations have not completed yet.
    graveyard: HashMap<u64, Box<Slot>>,
    next_term: u32,
    next_conn: u32,
    shutdown: bool,
    parse_batch: usize,
    inflight_max: usize,
    workers: Vec<std::sync::mpsc::Sender<ParseJob>>,
    tap_dir: Option<std::path::PathBuf>,
    spares: conpty::Spares,
    /// The last create: (microseconds to get a console, total).
    last_create_us: (u64, u64),
}

impl Server {
    fn run(&mut self) -> io::Result<()> {
        let mut entries = vec![OVERLAPPED_ENTRY::default(); 256];
        while !self.shutdown {
            let n = iocp::wait(&mut entries)?;
            for e in &entries[..n] {
                let key = e.lpCompletionKey as u64;
                let index = (key & INDEX_MASK) as u32;
                match key & !INDEX_MASK {
                    KIND_ACCEPT => self.accept(e.lpOverlapped as usize),
                    KIND_WAKE => self.batch_done(index),
                    KIND_EXIT => self.child_exited(index),
                    KIND_RESUME => self.pty_readable(index),
                    _ => {
                        // SAFETY: a packet for an overlapped operation; the
                        // OVERLAPPED lives in a slot we still own.
                        let status = unsafe { (*e.lpOverlapped).Internal };
                        self.io_done(key, e, status);
                    }
                }
            }
        }
        Ok(())
    }

    fn io_done(&mut self, key: u64, e: &OVERLAPPED_ENTRY, status: usize) {
        let index = (key & INDEX_MASK) as u32;
        let ov = e.lpOverlapped;
        let bytes = e.dwNumberOfBytesTransferred;
        let live = match key & !INDEX_MASK {
            KIND_CONN => self.conns.get_mut(&index).map(|c| &mut *c.slot),
            KIND_PTY_OUT => self.terms.get_mut(&index).map(|t| &mut *t.out),
            KIND_PTY_IN => self.terms.get_mut(&index).map(|t| &mut *t.input_slot),
            _ => None,
        };
        let done = match live {
            Some(slot) => slot.complete(ov, bytes, status),
            None => {
                if let Some(slot) = self.graveyard.get_mut(&key) {
                    slot.complete(ov, bytes, status);
                    if !slot.busy() {
                        self.graveyard.remove(&key);
                    }
                }
                return;
            }
        };
        match (key & !INDEX_MASK, done) {
            (KIND_CONN, Done::Read) => self.conn_readable(index),
            (KIND_CONN, Done::Write) => self.flush_conn(index),
            (KIND_PTY_OUT, Done::Read) => self.pty_readable(index),
            (KIND_PTY_IN, Done::Write) => self.flush_input(index),
            _ => {}
        }
    }

    /// Keeps `slot` until its cancelled operations complete.
    fn retire(&mut self, key: u64, mut slot: Box<Slot>) {
        slot.close();
        if slot.busy() {
            self.graveyard.insert(key, slot);
        }
    }

    fn accept(&mut self, socket: usize) {
        let id = self.next_conn;
        self.next_conn = self.next_conn.wrapping_add(1).max(1);
        let slot = match Slot::new(socket as HANDLE, true, KIND_CONN | u64::from(id)) {
            Ok(s) => s,
            Err(_) => {
                // SAFETY: closing a socket we were handed and cannot use.
                unsafe { windows_sys::Win32::Networking::WinSock::closesocket(socket) };
                return;
            }
        };
        self.conns.insert(
            id,
            Conn {
                slot,
                inbuf: Vec::new(),
                out: VecDeque::new(),
                front_sent: 0,
                queued: 0,
                attached: None,
                closing: false,
            },
        );
        self.conn_readable(id);
    }

    fn conn_readable(&mut self, id: u32) {
        let Some(conn) = self.conns.get_mut(&id) else { return };
        loop {
            match conn.slot.take_read() {
                Read::Data(buf, n) => {
                    conn.inbuf.extend_from_slice(&buf[..n]);
                    conn.slot.give_back(buf);
                }
                Read::Pending => break,
                Read::Eof => {
                    conn.closing = true;
                    break;
                }
            }
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
        if conn.closing && conn.out.is_empty() && !conn.slot.write_pending() {
            self.drop_conn(id);
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

    /// Hands queued frames to the socket, many frames per overlapped write.
    fn flush_conn(&mut self, id: u32) {
        let Some(conn) = self.conns.get_mut(&id) else { return };
        let mut failed = conn.slot.write_failed();
        while !failed && !conn.out.is_empty() && conn.slot.writable() {
            let Conn { slot, out, front_sent, queued, .. } = conn;
            let r = slot.write(|w| {
                while let Some(front) = out.front() {
                    let rest = &front[*front_sent..];
                    let room = iocp::WRITE_MAX.saturating_sub(w.len());
                    if room == 0 {
                        break;
                    }
                    let n = rest.len().min(room);
                    w.extend_from_slice(&rest[..n]);
                    *queued -= n;
                    *front_sent += n;
                    if *front_sent == front.len() {
                        out.pop_front();
                        *front_sent = 0;
                    }
                }
            });
            match r {
                Ok(true) => {}
                Ok(false) => break,
                Err(_) => failed = true,
            }
        }
        if failed {
            conn.out.clear();
            conn.front_sent = 0;
            conn.queued = 0;
            conn.closing = true;
        }
        // A write in flight is finished first: its packet calls this again.
        if conn.closing && conn.out.is_empty() && !conn.slot.write_pending() {
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
        self.retire(KIND_CONN | u64::from(id), conn.slot);
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
                    self.destroy(t, term);
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
                    let _ = term.vt().resize(cols, rows, 0, 0);
                    (term.cols, term.rows) = (cols, rows);
                    if let Some(hpc) = term.hpc {
                        conpty::resize(hpc, cols, rows);
                    }
                    self.flush_replies(t);
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
                let inflight: usize =
                    self.terms.values().map(|t| *t.inflight.count.lock().expect("inflight")).sum();
                let bytes: u64 = self.terms.values().map(|t| t.bytes_in).sum();
                let text = format!(
                    "pid\t{}\nterminals\t{}\nclients\t{}\npending_bytes\t{pending}\ninflight_batches\t{inflight}\nbytes_in\t{bytes}\nconpty\t{}\npassthrough_refused\t{}\nspare_consoles\t{}\nlast_create_us\tconsole={} total={}\n",
                    std::process::id(),
                    self.terms.len(),
                    self.conns.len(),
                    conpty::describe(),
                    conpty::passthrough_refused(),
                    self.spares.ready(),
                    self.last_create_us.0,
                    self.last_create_us.1,
                );
                self.send(id, proto::OK, text.as_bytes());
            }
            proto::UPGRADE => self.err(id, "upgrade in place is not supported on Windows"),
            proto::SHUTDOWN => {
                self.send(id, proto::OK, &[]);
                self.shutdown = true;
            }
            _ => self.err(id, "unknown request"),
        }
    }

    /// Ends a removed terminal: its whole job, its pseudoconsole, its pipes.
    fn destroy(&mut self, t: u32, term: Term) {
        conpty::unregister(term.wait);
        conpty::terminate(term.job);
        if let Some(hpc) = term.hpc {
            conpty::close_later(hpc);
        }
        conpty::close_handle(term.process);
        conpty::close_handle(term.job);
        self.retire(KIND_PTY_OUT | u64::from(t), term.out);
        self.retire(KIND_PTY_IN | u64::from(t), term.input_slot);
        for c in &term.attached {
            if let Some(conn) = self.conns.get_mut(c) {
                conn.attached = None;
            }
        }
        for c in term.attached.iter().chain(&term.waiters) {
            self.send(*c, proto::EXIT, &(-1i32).to_le_bytes());
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
            argv.push(utf8_os(r.bytes().ok_or_else(bad)?)?);
        }
        if argv.is_empty() {
            argv = conpty::default_argv();
        }
        let cwd = if cwd.is_empty() { None } else { Some(utf8_os(&cwd)?) };

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
        let t = self.next_term;
        let started = std::time::Instant::now();
        let console = self.spares.take(cols, rows)?;
        let got_console = started.elapsed();
        let child =
            conpty::spawn(console, &argv, cwd.as_deref(), cols, rows, KIND_EXIT | u64::from(t))?;
        self.last_create_us =
            (got_console.as_micros() as u64, started.elapsed().as_micros() as u64);
        self.next_term = self.next_term.wrapping_add(1).max(1);
        let cleanup = |child: &conpty::Child| {
            conpty::unregister(child.wait);
            conpty::terminate(child.job);
            conpty::close_later(child.hpc);
            conpty::close_handle(child.process);
            conpty::close_handle(child.job);
        };
        // Slot::new takes ownership of the handle only when it succeeds.
        let out = match Slot::new(child.out, false, KIND_PTY_OUT | u64::from(t)) {
            Ok(s) => s,
            Err(e) => {
                cleanup(&child);
                conpty::close_handle(child.out);
                conpty::close_handle(child.input);
                return Err(e);
            }
        };
        let input_slot = match Slot::new(child.input, false, KIND_PTY_IN | u64::from(t)) {
            Ok(s) => s,
            Err(e) => {
                cleanup(&child);
                conpty::close_handle(child.input);
                self.retire(KIND_PTY_OUT | u64::from(t), out);
                return Err(e);
            }
        };
        let tap = self
            .tap_dir
            .as_ref()
            .and_then(|d| std::fs::File::create(d.join(format!("{t}.raw"))).ok());
        self.terms.insert(
            t,
            Term {
                pid: child.pid,
                hpc: Some(child.hpc),
                out,
                input_slot,
                process: child.process,
                job: child.job,
                wait: child.wait,
                parser: Arc::new(Mutex::new(vt)),
                inflight: Arc::default(),
                open_seq: false,
                cols,
                rows,
                pending: Vec::new(),
                carry: Vec::new(),
                read_paused: false,
                replies,
                input: VecDeque::new(),
                attached: Vec::new(),
                waiters: Vec::new(),
                code: None,
                exit: None,
                pty_open: true,
                bytes_in: 0,
                tap,
            },
        );
        self.pty_readable(t);
        Ok(t)
    }

    fn flush_replies(&mut self, t: u32) {
        let Some(term) = self.terms.get_mut(&t) else { return };
        let replies = std::mem::take(&mut *term.replies.lock().expect("reply sink"));
        if !replies.is_empty() && term.pty_open {
            term.input.extend(replies);
        }
        self.flush_input(t);
    }

    /// Writes queued input; a write in flight finishes with a packet that
    /// calls this again. A program that does not read stalls only itself.
    fn flush_input(&mut self, t: u32) {
        let Some(term) = self.terms.get_mut(&t) else { return };
        while term.pty_open && !term.input.is_empty() && term.input_slot.writable() {
            let input = &mut term.input;
            let r = term.input_slot.write(|w| {
                let n = input.len().min(iocp::WRITE_MAX);
                w.extend(input.drain(..n));
            });
            match r {
                Ok(true) => {}
                Ok(false) => break,
                Err(_) => {
                    term.input.clear();
                    break;
                }
            }
        }
    }

    /// Parses (or batches) what conhost wrote, up to READ_BUDGET bytes.
    fn pty_readable(&mut self, t: u32) {
        let Some(term) = self.terms.get_mut(&t) else { return };
        if term.read_paused || !term.pty_open {
            return;
        }
        let watched = !term.attached.is_empty();
        let mut forwarded: Vec<u8> = Vec::new();
        let mut eof = false;
        let mut total = 0;
        let mut pause = false;
        let mut more = false;
        let (parse_batch, inflight_max) = (self.parse_batch, self.inflight_max);
        loop {
            if total >= READ_BUDGET {
                more = true;
                break;
            }
            let (buf, n) = match term.out.take_read() {
                Read::Data(buf, n) => (buf, n),
                Read::Pending => break,
                Read::Eof => {
                    eof = true;
                    break;
                }
            };
            let read = &buf[..n];
            total += n;
            term.bytes_in += n as u64;
            if let Some(tap) = term.tap.as_mut() {
                use std::io::Write;
                let _ = tap.write_all(read);
            }
            let joined;
            let data: &[u8] = if term.carry.is_empty() {
                read
            } else {
                term.carry.extend_from_slice(read);
                joined = std::mem::take(&mut term.carry);
                &joined
            };
            let (chunk, tail) =
                if watched { (data, &[][..]) } else { data.split_at(incomplete_tail_start(data)) };
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
                let replies = std::mem::take(&mut *term.replies.lock().expect("reply sink"));
                if !replies.is_empty() {
                    term.input.extend(replies);
                }
            } else {
                term.pending.extend_from_slice(chunk);
                if term.pending.len() >= parse_batch {
                    let worker = (!self.workers.is_empty())
                        .then(|| &self.workers[t as usize % self.workers.len()]);
                    offload_parse(term, worker, &self.waker, t);
                    if *term.inflight.count.lock().expect("inflight") >= inflight_max {
                        // The read already in flight completes later; it is
                        // taken when the worker catches up.
                        term.read_paused = true;
                        pause = true;
                    }
                }
            }
            term.carry.extend_from_slice(tail);
            term.out.give_back(buf);
            if pause {
                break;
            }
        }
        let clients = if forwarded.is_empty() { Vec::new() } else { term.attached.clone() };
        if eof {
            term.pty_open = false;
            term.input.clear();
        }
        // Query replies go out before anything else happens.
        self.flush_input(t);
        if !clients.is_empty() {
            self.fanout(t, &clients, &forwarded);
        }
        if more {
            iocp::post(KIND_RESUME | u64::from(t), 0);
        }
        if eof {
            self.finish(t);
        }
    }

    fn batch_done(&mut self, t: u32) {
        self.flush_replies(t);
        let Some(term) = self.terms.get_mut(&t) else { return };
        let below = *term.inflight.count.lock().expect("inflight") < self.inflight_max;
        if term.read_paused && below {
            term.read_paused = false;
            self.pty_readable(t);
        }
    }

    fn fanout(&mut self, t: u32, clients: &[u32], bytes: &[u8]) {
        for &c in clients {
            let behind = self.conns.get(&c).map_or(0, |conn| conn.queued);
            if behind > CLIENT_BACKLOG_MAX {
                self.snapshot_to(t, c);
            } else {
                self.send(c, proto::OUTPUT, bytes);
            }
        }
    }

    /// The program exited: close the pseudoconsole so conhost writes its
    /// last frame and ends the output pipe; EXIT follows from `finish`.
    fn child_exited(&mut self, t: u32) {
        let Some(term) = self.terms.get_mut(&t) else { return };
        let mut code = 0u32;
        // SAFETY: reading the exit code of our exited child.
        let ok = unsafe { GetExitCodeProcess(term.process, &mut code) } != 0;
        term.code = Some(if ok { code as i32 } else { -1 });
        conpty::unregister(std::mem::replace(&mut term.wait, std::ptr::null_mut()));
        if let Some(hpc) = term.hpc.take() {
            conpty::close_later(hpc);
        }
        if !term.pty_open {
            self.finish(t);
        }
    }

    /// Sends EXIT once both the program has exited and every byte of its
    /// output has been parsed.
    fn finish(&mut self, t: u32) {
        let Some(term) = self.terms.get_mut(&t) else { return };
        let Some(code) = term.code else { return };
        if term.exit.is_some() || term.pty_open {
            return;
        }
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

fn utf8_os(bytes: &[u8]) -> io::Result<OsString> {
    let s = std::str::from_utf8(bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "argument is not UTF-8"))?;
    if s.contains('\0') {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "argument contains NUL"));
    }
    let wide: Vec<u16> = s.encode_utf16().collect();
    Ok(OsString::from_wide(&wide))
}

/// Binds the socket and runs the accept thread, which hands each accepted
/// socket to the loop through the port.
fn listen(path: &std::path::Path) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    if proto::connect(path).is_ok() {
        return Err(io::Error::new(io::ErrorKind::AddrInUse, "a server already listens"));
    }
    let _ = std::fs::remove_file(path);
    let listener = uds_windows::UnixListener::bind(path)?;
    std::thread::Builder::new().name("mux2-accept".into()).spawn(move || {
        loop {
            match listener.accept() {
                Ok((stream, _)) => iocp::post(KIND_ACCEPT, stream.into_raw_socket() as usize),
                Err(_) => continue,
            }
        }
    })?;
    Ok(())
}

pub fn main() {
    let path = proto::socket_path();
    // MUX2_READY_EVENT: a named event the starting client waits on.
    let ready = std::env::var_os("MUX2_READY_EVENT");
    // SAFETY: single-threaded at this point.
    unsafe { std::env::remove_var("MUX2_READY_EVENT") };
    if let Err(e) = iocp::create_port() {
        eprintln!("mux2d: completion port: {e}");
        std::process::exit(1);
    }
    if let Err(e) = listen(&path) {
        eprintln!("mux2d: cannot listen on {}: {e}", path.display());
        std::process::exit(1);
    }
    let tap_dir = std::env::var_os("MUX2_TAP_DIR").map(std::path::PathBuf::from);
    if let Some(d) = &tap_dir {
        let _ = std::fs::create_dir_all(d);
    }
    let mut server = Server {
        waker: Waker,
        terms: HashMap::new(),
        conns: HashMap::new(),
        graveyard: HashMap::new(),
        next_term: 1,
        next_conn: 1,
        shutdown: false,
        parse_batch: tunable("MUX2_PARSE_BATCH", PARSE_BATCH),
        inflight_max: tunable("MUX2_INFLIGHT_MAX", INFLIGHT_MAX).max(1),
        workers: spawn_parse_workers(),
        tap_dir,
        spares: conpty::Spares::start(tunable("MUX2_SPARE_CONSOLES", 1)),
        last_create_us: (0, 0),
    };
    if let Some(name) = ready {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::System::Threading::{EVENT_MODIFY_STATE, OpenEventW, SetEvent};
        let name: Vec<u16> = name.encode_wide().chain(Some(0)).collect();
        // SAFETY: opening the client's named event and setting it.
        unsafe {
            let h = OpenEventW(EVENT_MODIFY_STATE, 0, name.as_ptr());
            if !h.is_null() {
                SetEvent(h);
                conpty::close_handle(h);
            }
        }
    }
    if let Err(e) = server.run() {
        eprintln!("mux2d: {e}");
    }
    // KILL_ON_JOB_CLOSE would end the programs when the process exits;
    // ending them first makes the order explicit. Slots are not dropped:
    // their operations are still in flight and the process exits now.
    for term in server.terms.values() {
        conpty::terminate(term.job);
    }
    let _ = std::fs::remove_file(&path);
    std::process::exit(0);
}
