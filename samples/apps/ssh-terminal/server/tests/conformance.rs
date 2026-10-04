//! Conformance vectors for `cmux.terminal.backend/1` (bytes mode).
//!
//! The `vectors` module uses only the interface (`ssh_terminal::iface`, a
//! mirror of the real crate) and the [`vectors::FarEnd`] trait, so another
//! backend (the Cloud rescue shell, helper C2) can copy it and run the same
//! vectors with its own far end. The far end must run the tiny shell from
//! README "Conformance": `echo X` answers `X\r\n`; `exit N` exits with N.
//! The bottom of this file runs every vector against the SSH backend and an
//! in-process SSH server.

mod common;

pub mod vectors {
    use ssh_terminal::iface::{
        BackendError, ByteEvent, ByteTerminal, Close, ExitStatus, Grid, Input, OpenRequest,
        TerminalBackend,
    };
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    const WAIT: Duration = Duration::from_secs(10);
    const TICK: Duration = Duration::from_millis(10);

    /// The test's view of the far end of one backend.
    pub trait FarEnd {
        fn backend(&mut self) -> &mut dyn TerminalBackend;
        /// A kind the backend serves.
        fn kind(&self) -> String;
        /// An open request for `kind` (or any other kind) and a target that works.
        fn request(&self, kind: &str, terminal: &str, grid: Grid) -> OpenRequest;
        /// Input bytes the far end received so far, in arrival order.
        fn received(&self) -> Vec<u8>;
        /// The grid the far end knows now (open size, then each resize).
        fn grid(&self) -> Option<Grid>;
        /// Breaks the transport without a goodbye.
        fn drop_transport(&self);
    }

    fn take_until(
        t: &mut dyn ByteTerminal,
        what: &str,
        done: impl Fn(&[ByteEvent]) -> bool,
    ) -> Vec<ByteEvent> {
        let deadline = Instant::now() + WAIT;
        let mut all = Vec::new();
        loop {
            all.extend(t.take_events());
            if done(&all) {
                return all;
            }
            assert!(Instant::now() < deadline, "never saw {what}: {all:?}");
            std::thread::sleep(TICK);
        }
    }

    fn wait_far(what: &str, check: impl Fn() -> bool) {
        let deadline = Instant::now() + WAIT;
        while !check() {
            assert!(Instant::now() < deadline, "far end never saw {what}");
            std::thread::sleep(TICK);
        }
    }

    fn output(events: &[ByteEvent]) -> Vec<u8> {
        let mut out = Vec::new();
        for event in events {
            if let ByteEvent::Output(bytes) = event {
                out.extend_from_slice(bytes);
            }
        }
        out
    }

    fn has(bytes: &[u8], needle: &str) -> bool {
        bytes.windows(needle.len()).any(|w| w == needle.as_bytes())
    }

    fn input(seq: u64, text: &str) -> Input {
        Input { seq, bytes: text.as_bytes().to_vec() }
    }

    const GRID: Grid = Grid { cols: 80, rows: 24 };

    fn open(far: &mut dyn FarEnd, terminal: &str) -> Box<dyn ByteTerminal> {
        let request = far.request(&far.kind(), terminal, GRID);
        far.backend().open(request).expect("open")
    }

    /// Default deny: a kind outside `options.kinds` is refused.
    pub fn other_kind_is_refused(far: &mut dyn FarEnd) {
        let request = far.request("telnet", "t-kind", GRID);
        let refused = far.backend().open(request).err();
        assert_eq!(refused, Some(BackendError::KindRefused { kind: "telnet".into() }));
        assert!(far.received().is_empty());
    }

    /// Input reaches the far end; its output comes back as `output` events.
    pub fn echo_round_trip(far: &mut dyn FarEnd) {
        let mut t = open(far, "t-echo");
        t.write(input(0, "echo hi\n")).expect("write");
        let events = take_until(t.as_mut(), "hi", |e| has(&output(e), "hi"));
        assert!(has(&output(&events), "hi\r\n"));
    }

    /// Writes from many threads, with seqs out of order, arrive in seq order.
    pub fn concurrent_writes_keep_seq_order(far: &mut dyn FarEnd) {
        let t: Arc<Mutex<Box<dyn ByteTerminal>>> = Arc::new(Mutex::new(open(far, "t-order")));
        let (threads, per_thread) = (8u64, 8u64);
        let mut joins = Vec::new();
        for lane in 0..threads {
            let t = t.clone();
            joins.push(std::thread::spawn(move || {
                // Each lane writes its seqs from the highest down, so most
                // chunks arrive before an earlier seq.
                for i in (0..per_thread).rev() {
                    let seq = lane + i * threads;
                    t.lock()
                        .expect("terminal")
                        .write(input(seq, &format!("<{seq:03}>")))
                        .expect("w");
                }
            }));
        }
        for join in joins {
            join.join().expect("writer thread");
        }
        let total = threads * per_thread;
        let want: String = (0..total).map(|seq| format!("<{seq:03}>")).collect();
        wait_far("every chunk", || far.received().len() >= want.len());
        assert_eq!(String::from_utf8_lossy(&far.received()), want);
        let again = t.lock().expect("terminal").write(input(3, "x"));
        assert!(matches!(again, Err(BackendError::Invalid(_))), "a seq is written once: {again:?}");
    }

    /// The open size and every resize reach the far end.
    pub fn resize_reaches_far_end(far: &mut dyn FarEnd) {
        let t = open(far, "t-resize");
        wait_far("the open grid", || far.grid() == Some(GRID));
        let bigger = Grid { cols: 132, rows: 43 };
        t.resize(bigger).expect("resize");
        wait_far("the new grid", || far.grid() == Some(bigger));
    }

    /// A far-end exit gives `exit` with the status, then nothing is accepted.
    pub fn far_exit_gives_exit_status(far: &mut dyn FarEnd) {
        let mut t = open(far, "t-exit");
        t.write(input(0, "exit 3\n")).expect("write");
        let events = take_until(t.as_mut(), "exit", |e| e.iter().any(is_end));
        assert_eq!(
            events.iter().find(|e| is_end(e)),
            Some(&ByteEvent::Exit(ExitStatus { code: Some(3) }))
        );
        assert_eq!(t.write(input(1, "late\n")), Err(BackendError::Closed));
        assert!(t.take_events().is_empty(), "nothing after the end event");
    }

    /// A broken transport gives `lost`, never `exit`.
    pub fn transport_drop_gives_lost(far: &mut dyn FarEnd) {
        let mut t = open(far, "t-lost");
        t.write(input(0, "echo up\n")).expect("write");
        take_until(t.as_mut(), "up", |e| has(&output(e), "up"));
        far.drop_transport();
        let events = take_until(t.as_mut(), "lost", |e| e.iter().any(is_end));
        assert!(matches!(events.last(), Some(ByteEvent::Lost(_))), "{events:?}");
        assert_eq!(t.write(input(1, "late\n")), Err(BackendError::Closed));
    }

    /// After `close` every call is refused and nothing queues.
    pub fn close_refuses_later_calls(far: &mut dyn FarEnd) {
        let t = open(far, "t-close");
        t.close(Close::Graceful).expect("close");
        assert_eq!(t.write(input(0, "echo no\n")), Err(BackendError::Closed));
        assert_eq!(t.resize(Grid { cols: 10, rows: 10 }), Err(BackendError::Closed));
        assert_eq!(t.close(Close::Now), Err(BackendError::Closed));
    }

    /// With capability `resume`: a token taken after some output resumes at
    /// that offset (no repeat), input seqs go on, and a bad token gives `lost`.
    pub fn resume_continues_at_offset(far: &mut dyn FarEnd) {
        if !far.backend().capabilities().resume {
            return;
        }
        let mut t = open(far, "t-resume");
        t.write(input(0, "echo one\n")).expect("write");
        take_until(t.as_mut(), "one", |e| has(&output(e), "one"));
        let token = t.resume_token().expect("token");
        drop(t);
        let mut again = far.backend().resume(&token).expect("resume");
        again.write(input(1, "echo two\n")).expect("write after resume");
        let events = take_until(again.as_mut(), "two", |e| has(&output(e), "two"));
        assert!(!has(&output(&events), "one"), "resume repeats nothing: {events:?}");
        let mut twice = far.backend().resume(&token).expect("resume while attached");
        let lost = take_until(twice.as_mut(), "lost", |e| !e.is_empty());
        assert!(matches!(lost.as_slice(), [ByteEvent::Lost(_)]), "{lost:?}");
        again.close(Close::Now).expect("close");
        let mut gone = far.backend().resume(&token).expect("resume after close");
        let lost = take_until(gone.as_mut(), "lost", |e| !e.is_empty());
        assert!(matches!(lost.as_slice(), [ByteEvent::Lost(_)]), "{lost:?}");
    }

    fn is_end(event: &ByteEvent) -> bool {
        matches!(event, ByteEvent::Exit(_) | ByteEvent::Lost(_))
    }
}

// --- The SSH backend against an in-process SSH server. ---

use common::{Fixture, Trust, fixture, request};
use ssh_terminal::SSH_KIND;
use ssh_terminal::iface::{Grid, OpenRequest, TerminalBackend};
use vectors::FarEnd;

struct SshFar(Fixture);

impl FarEnd for SshFar {
    fn backend(&mut self) -> &mut dyn TerminalBackend {
        &mut self.0.backend
    }
    fn kind(&self) -> String {
        SSH_KIND.into()
    }
    fn request(&self, kind: &str, terminal: &str, grid: Grid) -> OpenRequest {
        request(kind, terminal, grid)
    }
    fn received(&self) -> Vec<u8> {
        self.0.server.log().input
    }
    fn grid(&self) -> Option<Grid> {
        let log = self.0.server.log();
        let (cols, rows) = log.windows.last().copied().or(log.pty)?;
        Some(Grid { cols: u16::try_from(cols).ok()?, rows: u16::try_from(rows).ok()? })
    }
    fn drop_transport(&self) {
        self.0.server.kill_connections();
    }
}

fn far() -> SshFar {
    SshFar(fixture(Trust::Known))
}

#[test]
fn ssh_other_kind_is_refused() {
    vectors::other_kind_is_refused(&mut far());
}

#[test]
fn ssh_echo_round_trip() {
    vectors::echo_round_trip(&mut far());
}

#[test]
fn ssh_concurrent_writes_keep_seq_order() {
    vectors::concurrent_writes_keep_seq_order(&mut far());
}

#[test]
fn ssh_resize_reaches_far_end() {
    vectors::resize_reaches_far_end(&mut far());
}

#[test]
fn ssh_far_exit_gives_exit_status() {
    vectors::far_exit_gives_exit_status(&mut far());
}

#[test]
fn ssh_transport_drop_gives_lost() {
    vectors::transport_drop_gives_lost(&mut far());
}

#[test]
fn ssh_close_refuses_later_calls() {
    vectors::close_refuses_later_calls(&mut far());
}

#[test]
fn ssh_resume_continues_at_offset() {
    vectors::resume_continues_at_offset(&mut far());
}
