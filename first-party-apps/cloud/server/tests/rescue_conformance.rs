//! Conformance vectors for `cmux.terminal.backend/1` (bytes mode), run
//! against the Cloud rescue backend with a fake transport.
//!
//! The `vectors` module is COPIED from
//! `samples/apps/ssh-terminal/server/tests/conformance.rs` at commit
//! 1aecb243404 (unchanged through c2c11692927). Only the import path
//! changed (`ssh_terminal::iface` to `cmux_cloud::rescue::iface`). Keep it
//! byte-equal otherwise; when the real crate lands, both copies move to it.
//! The bottom of this file runs every vector against [`RescueBackend`] over
//! a fake transport that runs the tiny shell of the sample README
//! ("Conformance"): `echo X` answers `X\r\n`; `exit N` exits with N;
//! `flood N` answers N KiB of output.

pub mod vectors {
    use cmux_cloud::rescue::iface::{
        BackendError, ByteEvent, ByteTerminal, Close, ExitStatus, Grid, Input, OpenRequest,
        OpenToken, ResumeRequest, Signal, TerminalBackend,
    };
    use std::sync::{Arc, Mutex};
    use std::time::{Duration, Instant};

    const WAIT: Duration = Duration::from_secs(10);
    const TICK: Duration = Duration::from_millis(5);

    /// The test's view of the far end of one backend.
    pub trait FarEnd {
        fn backend(&mut self) -> &mut dyn TerminalBackend;
        /// A kind the backend serves.
        fn kind(&self) -> String;
        /// An open request for `kind` (or any other kind), a target that
        /// works and a fresh `open_token`.
        fn request(&self, kind: &str, terminal: &str, grid: Grid) -> OpenRequest;
        /// A fresh `open_token` for a resume.
        fn open_token(&self) -> OpenToken;
        /// Input bytes the far end received so far, in arrival order.
        fn received(&self) -> Vec<u8>;
        /// The `(cols, rows)` the far end knows now (open size, then each resize).
        fn grid(&self) -> Option<(u16, u16)>;
        /// Signal names (without `SIG`) the far end received, in order.
        fn signals(&self) -> Vec<String>;
        /// Breaks the transport without a goodbye.
        fn drop_transport(&self);
        /// The most delivered output bytes the backend keeps for `resume`.
        fn retained_bytes(&self) -> usize;
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
            if let ByteEvent::Output { bytes, .. } = event {
                out.extend_from_slice(bytes);
            }
        }
        out
    }

    /// The offset after the last output chunk in `events`.
    fn last_offset(events: &[ByteEvent]) -> Option<u64> {
        events.iter().rev().find_map(|e| match e {
            ByteEvent::Output { offset, .. } => Some(*offset),
            _ => None,
        })
    }

    /// Every output chunk starts where the one before it ended.
    fn assert_contiguous(from: u64, events: &[ByteEvent]) {
        let mut at = from;
        for event in events {
            if let ByteEvent::Output { offset, bytes } = event {
                assert!(!bytes.is_empty(), "an output event carries bytes");
                assert_eq!(*offset, at + bytes.len() as u64, "a gap or an overlap after {at}");
                at = *offset;
            }
        }
    }

    fn has(bytes: &[u8], needle: &str) -> bool {
        bytes.windows(needle.len()).any(|w| w == needle.as_bytes())
    }

    fn input(seq: u64, text: &str) -> Input {
        Input { seq, bytes: text.as_bytes().to_vec() }
    }

    fn is_end(event: &ByteEvent) -> bool {
        matches!(event, ByteEvent::Exit(_) | ByteEvent::Lost { .. })
    }

    fn not_open(result: Result<(), BackendError>) -> bool {
        matches!(result, Err(BackendError::Invalid { .. }))
    }

    const GRID: Grid = Grid::new(80, 24);

    fn open(far: &mut dyn FarEnd, terminal: &str) -> Box<dyn ByteTerminal> {
        let request = far.request(&far.kind(), terminal, GRID);
        far.backend().open(request).expect("open")
    }

    /// Default deny: a kind outside `options.kinds` is refused.
    pub fn other_kind_is_refused(far: &mut dyn FarEnd) {
        let request = far.request("telnet", "t-kind", GRID);
        let refused = far.backend().open(request).err();
        assert!(matches!(refused, Some(BackendError::Denied { .. })), "{refused:?}");
        assert!(far.received().is_empty());
    }

    /// A shell over a byte pipe never answers terminal queries itself.
    pub fn plain_shell_does_not_answer_queries(far: &mut dyn FarEnd) {
        assert!(!far.backend().capabilities().answers_queries);
    }

    /// Input reaches the far end; its output comes back as `output` events.
    pub fn echo_round_trip(far: &mut dyn FarEnd) {
        let mut t = open(far, "t-echo");
        t.write(input(0, "echo hi\n")).expect("write");
        let events = take_until(t.as_mut(), "hi", |e| has(&output(e), "hi"));
        assert!(has(&output(&events), "hi\r\n"));
    }

    /// `output.offset` is the running byte total after each chunk, with no
    /// gap and no overlap, also over many chunks.
    pub fn output_offsets_are_contiguous(far: &mut dyn FarEnd) {
        let mut t = open(far, "t-offsets");
        t.write(input(0, "flood 200\n")).expect("write");
        let want = 200 * 1024;
        let events = take_until(t.as_mut(), "200 KiB", |e| output(e).len() >= want);
        assert!(events.iter().filter(|e| matches!(e, ByteEvent::Output { .. })).count() > 1);
        assert_contiguous(0, &events);
        assert_eq!(last_offset(&events), Some(output(&events).len() as u64));
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
        assert!(not_open(again.clone()), "a seq is written once: {again:?}");
    }

    /// The open size and every resize reach the far end.
    pub fn resize_reaches_far_end(far: &mut dyn FarEnd) {
        let t = open(far, "t-resize");
        wait_far("the open grid", || far.grid() == Some((80, 24)));
        t.resize(Grid::new(132, 43)).expect("resize");
        wait_far("the new grid", || far.grid() == Some((132, 43)));
    }

    /// A signal reaches the far end by name.
    pub fn signal_reaches_far_end(far: &mut dyn FarEnd) {
        let t = open(far, "t-signal");
        t.signal(Signal::Interrupt).expect("signal");
        wait_far("INT", || far.signals().iter().any(|s| s == "INT"));
    }

    /// A far-end exit gives `exit` with the status, then nothing is accepted.
    pub fn far_exit_gives_exit_status(far: &mut dyn FarEnd) {
        let mut t = open(far, "t-exit");
        t.write(input(0, "exit 3\n")).expect("write");
        let events = take_until(t.as_mut(), "exit", |e| e.iter().any(is_end));
        let want = ExitStatus { code: Some(3), signal: None, core_dumped: false, message: None };
        assert_eq!(events.iter().find(|e| is_end(e)), Some(&ByteEvent::Exit(want)));
        assert!(not_open(t.write(input(1, "late\n"))));
        assert!(t.take_events().is_empty(), "nothing after the end event");
    }

    /// A broken transport gives `lost {reason, retryable}`, never `exit`.
    pub fn transport_drop_gives_lost(far: &mut dyn FarEnd) {
        let mut t = open(far, "t-lost");
        t.write(input(0, "echo up\n")).expect("write");
        take_until(t.as_mut(), "up", |e| has(&output(e), "up"));
        far.drop_transport();
        let events = take_until(t.as_mut(), "lost", |e| e.iter().any(is_end));
        assert!(
            matches!(events.last(), Some(ByteEvent::Lost { reason, .. }) if !reason.is_empty()),
            "{events:?}"
        );
        assert!(not_open(t.write(input(1, "late\n"))));
    }

    /// After `close` every call is refused and nothing queues.
    pub fn close_refuses_later_calls(far: &mut dyn FarEnd) {
        let t = open(far, "t-close");
        t.close(Close::Graceful).expect("close");
        assert!(not_open(t.write(input(0, "echo no\n"))));
        assert!(not_open(t.resize(Grid::new(10, 10))));
        assert!(not_open(t.signal(Signal::Interrupt)));
        assert!(not_open(t.close(Close::Now)));
    }

    /// With capability `resume`: a token taken after some output resumes at
    /// that offset (no repeat, offsets go on), input seqs go on, and a token
    /// of a closed terminal gives `lost`.
    pub fn resume_continues_at_offset(far: &mut dyn FarEnd) {
        if !far.backend().capabilities().resume {
            return;
        }
        let mut t = open(far, "t-resume");
        t.write(input(0, "echo one\n")).expect("write");
        let first = take_until(t.as_mut(), "one", |e| has(&output(e), "one"));
        let at = last_offset(&first).expect("offset");
        let token = t.resume_token().expect("token");
        drop(t);
        let resume = |far: &mut dyn FarEnd| {
            let request =
                ResumeRequest { resume_token: token.clone(), open_token: far.open_token() };
            far.backend().resume(request)
        };
        let resumed = resume(far).expect("resume");
        assert_eq!(resumed.offset, at, "resume continues where the host stopped reading");
        let mut again = resumed.terminal;
        again.write(input(1, "echo two\n")).expect("write after resume");
        let events = take_until(again.as_mut(), "two", |e| has(&output(e), "two"));
        assert!(!has(&output(&events), "one"), "resume repeats nothing: {events:?}");
        assert_contiguous(at, &events);
        let twice = resume(far).err();
        assert!(matches!(twice, Some(BackendError::Invalid { .. })), "attached: {twice:?}");
        again.close(Close::Now).expect("close");
        let mut gone = resume(far).expect("resume after close").terminal;
        let lost = take_until(gone.as_mut(), "lost", |e| !e.is_empty());
        assert!(matches!(lost.as_slice(), [ByteEvent::Lost { .. }]), "{lost:?}");
    }

    /// A resume from an offset older than the kept output gives `lost`.
    pub fn resume_with_a_stale_offset_is_lost(far: &mut dyn FarEnd) {
        if !far.backend().capabilities().resume {
            return;
        }
        let mut t = open(far, "t-stale");
        t.write(input(0, "echo early\n")).expect("write");
        take_until(t.as_mut(), "early", |e| has(&output(e), "early"));
        let stale = t.resume_token().expect("token");
        let kib = far.retained_bytes() / 1024 + 64;
        t.write(input(1, &format!("flood {kib}\n"))).expect("write");
        take_until(t.as_mut(), "the flood", |e| output(e).len() >= kib * 1024);
        drop(t);
        let request = ResumeRequest { resume_token: stale, open_token: far.open_token() };
        let mut lost = far.backend().resume(request).expect("resume answers").terminal;
        let events = take_until(lost.as_mut(), "lost", |e| !e.is_empty());
        assert!(matches!(events.as_slice(), [ByteEvent::Lost { .. }]), "{events:?}");
        assert!(not_open(lost.write(input(2, "echo no\n"))));
    }
}

// --- The rescue backend over a fake transport that runs the tiny shell. ---

use cmux_cloud::rescue::iface::{
    BackendError, ExitStatus, Grid, OpenRequest, OpenToken, Signal, TerminalBackend,
};
use cmux_cloud::rescue::{RESCUE_KIND, RescueBackend, RescueTransport, StreamId, TransportEvent};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use vectors::FarEnd;

/// Output of `flood` goes out in chunks of this size.
const CHUNK: usize = 16 * 1024;

#[derive(Default)]
struct Shell {
    received: Vec<u8>,
    grid: Option<(u16, u16)>,
    signals: Vec<String>,
    lines: HashMap<StreamId, Vec<u8>>,
    events: Vec<(StreamId, TransportEvent)>,
    next: StreamId,
}

impl Shell {
    fn run(&mut self, stream: StreamId, line: &str) {
        let line = line.trim_end_matches('\r');
        if let Some(text) = line.strip_prefix("echo ") {
            let out = format!("{text}\r\n").into_bytes();
            self.events.push((stream, TransportEvent::Output(out)));
        } else if let Some(code) = line.strip_prefix("exit ") {
            let code = code.trim().parse().ok();
            let status = ExitStatus { code, ..ExitStatus::default() };
            self.events.push((stream, TransportEvent::Closed(status)));
        } else if let Some(kib) = line.strip_prefix("flood ") {
            let mut left = kib.trim().parse::<usize>().unwrap_or(0) * 1024;
            while left > 0 {
                let n = left.min(CHUNK);
                self.events.push((stream, TransportEvent::Output(vec![b'x'; n])));
                left -= n;
            }
        }
    }
}

/// A rescue transport whose far end is the tiny shell, in memory.
#[derive(Clone, Default)]
struct ShellTransport(Arc<Mutex<Shell>>);

impl ShellTransport {
    fn lock(&self) -> MutexGuard<'_, Shell> {
        self.0.lock().unwrap()
    }
}

impl RescueTransport for ShellTransport {
    fn open(&mut self, _machine: &str, grid: Grid) -> Result<StreamId, BackendError> {
        let mut shell = self.lock();
        shell.next += 1;
        shell.grid = Some((grid.cols, grid.rows));
        let id = shell.next;
        shell.lines.insert(id, Vec::new());
        Ok(id)
    }

    fn write(&mut self, stream: StreamId, bytes: &[u8]) -> Result<(), BackendError> {
        let mut shell = self.lock();
        shell.received.extend_from_slice(bytes);
        let mut line = shell.lines.remove(&stream).unwrap_or_default();
        line.extend_from_slice(bytes);
        while let Some(end) = line.iter().position(|b| *b == b'\n') {
            let command: Vec<u8> = line.drain(..=end).collect();
            let command = String::from_utf8_lossy(&command[..command.len() - 1]).into_owned();
            shell.run(stream, &command);
        }
        shell.lines.insert(stream, line);
        Ok(())
    }

    fn resize(&mut self, _stream: StreamId, grid: Grid) -> Result<(), BackendError> {
        self.lock().grid = Some((grid.cols, grid.rows));
        Ok(())
    }

    fn signal(&mut self, _stream: StreamId, signal: Signal) -> Result<(), BackendError> {
        self.lock().signals.push(signal.name().to_owned());
        Ok(())
    }

    fn close(&mut self, stream: StreamId) -> Result<(), BackendError> {
        self.lock().lines.remove(&stream);
        Ok(())
    }

    fn take_events(&mut self) -> Vec<(StreamId, TransportEvent)> {
        std::mem::take(&mut self.lock().events)
    }
}

struct RescueFar {
    backend: RescueBackend,
    shell: ShellTransport,
}

impl FarEnd for RescueFar {
    fn backend(&mut self) -> &mut dyn TerminalBackend {
        &mut self.backend
    }
    fn kind(&self) -> String {
        RESCUE_KIND.into()
    }
    fn request(&self, kind: &str, terminal: &str, grid: Grid) -> OpenRequest {
        OpenRequest {
            kind: kind.into(),
            terminal: terminal.into(),
            target: "vm-alpha01".into(),
            open_token: self.open_token(),
            command: None,
            cwd: None,
            env: Vec::new(),
            grid,
            actor: None,
        }
    }
    fn open_token(&self) -> OpenToken {
        OpenToken("open-token-test".into())
    }
    fn received(&self) -> Vec<u8> {
        self.shell.lock().received.clone()
    }
    fn grid(&self) -> Option<(u16, u16)> {
        self.shell.lock().grid
    }
    fn signals(&self) -> Vec<String> {
        self.shell.lock().signals.clone()
    }
    fn drop_transport(&self) {
        let mut shell = self.shell.lock();
        let open: Vec<StreamId> = shell.lines.keys().copied().collect();
        for stream in open {
            let reason = "the network dropped".to_owned();
            shell.events.push((stream, TransportEvent::Dropped { reason, retryable: true }));
        }
    }
    fn retained_bytes(&self) -> usize {
        // No resume (capability `resume: false`): nothing is kept.
        0
    }
}

fn far() -> RescueFar {
    let shell = ShellTransport::default();
    RescueFar { backend: RescueBackend::new(Box::new(shell.clone())), shell }
}

#[test]
fn rescue_other_kind_is_refused() {
    vectors::other_kind_is_refused(&mut far());
}

#[test]
fn rescue_plain_shell_does_not_answer_queries() {
    vectors::plain_shell_does_not_answer_queries(&mut far());
}

#[test]
fn rescue_echo_round_trip() {
    vectors::echo_round_trip(&mut far());
}

#[test]
fn rescue_output_offsets_are_contiguous() {
    vectors::output_offsets_are_contiguous(&mut far());
}

#[test]
fn rescue_concurrent_writes_keep_seq_order() {
    vectors::concurrent_writes_keep_seq_order(&mut far());
}

#[test]
fn rescue_resize_reaches_far_end() {
    vectors::resize_reaches_far_end(&mut far());
}

#[test]
fn rescue_signal_reaches_far_end() {
    vectors::signal_reaches_far_end(&mut far());
}

#[test]
fn rescue_far_exit_gives_exit_status() {
    vectors::far_exit_gives_exit_status(&mut far());
}

#[test]
fn rescue_transport_drop_gives_lost() {
    vectors::transport_drop_gives_lost(&mut far());
}

#[test]
fn rescue_close_refuses_later_calls() {
    vectors::close_refuses_later_calls(&mut far());
}

#[test]
fn rescue_resume_continues_at_offset() {
    vectors::resume_continues_at_offset(&mut far());
}

#[test]
fn rescue_resume_with_a_stale_offset_is_lost() {
    vectors::resume_with_a_stale_offset_is_lost(&mut far());
}
