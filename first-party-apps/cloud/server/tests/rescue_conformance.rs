//! Conformance vectors for `cmux.terminal.backend/1` (bytes mode, the
//! shared `cmux-terminal-iface` crate), run against the Cloud rescue backend
//! with a fake transport.
//!
//! The `vectors` module started as a copy of
//! `samples/apps/ssh-terminal/server/tests/conformance.rs` (1aecb243404).
//! It now drives the shared frame shapes (data, credit, end), which the
//! sample's mirror does not have yet; when the sample moves to the shared
//! crate, both should share one copy. The bottom of this file runs every
//! vector against [`RescueBackend`] over a fake transport that runs the tiny
//! shell of the sample README ("Conformance"): `echo X` answers `X\r\n`;
//! `exit N` exits with N; `flood N` answers N KiB of output.
//!
//! The sample's two resume vectors are not here: the rescue backend has
//! capability `resume: false`, so they returned at once (attach_rescue.rs
//! checks that resume is `unsupported`).

mod frames_common;

pub mod vectors {
    use super::frames_common::{Host, MAX_FRAME, end, last_offset, not_open, output};
    use cmux_terminal_iface::{
        BackendError, Close, Direction, End, ExitStatus, FrameBody, Grid, Lost, OpenRequest,
        Signal, TerminalBackend,
    };
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
        /// Input bytes the far end received so far, in arrival order.
        fn received(&self) -> Vec<u8>;
        /// The `(cols, rows)` the far end knows now (open size, then each resize).
        fn grid(&self) -> Option<(u16, u16)>;
        /// Signal names (without `SIG`) the far end received, in order.
        fn signals(&self) -> Vec<String>;
        /// Breaks the transport without a goodbye.
        fn drop_transport(&self);
    }

    fn take_until(
        host: &mut Host,
        what: &str,
        done: impl Fn(&[FrameBody]) -> bool,
    ) -> Vec<FrameBody> {
        let deadline = Instant::now() + WAIT;
        let mut all = Vec::new();
        loop {
            all.extend(host.take());
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

    fn has(bytes: &[u8], needle: &str) -> bool {
        bytes.windows(needle.len()).any(|w| w == needle.as_bytes())
    }

    fn ended(frames: &[FrameBody]) -> bool {
        end(frames).is_some()
    }

    const GRID: Grid = Grid::new(80, 24);

    fn open(far: &mut dyn FarEnd, terminal: &str) -> Host {
        let request = far.request(&far.kind(), terminal, GRID);
        Host::new(far.backend().open(request).expect("open"))
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

    /// Input reaches the far end; its output comes back as data frames.
    pub fn echo_round_trip(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-echo");
        host.write(b"echo hi\n").expect("write");
        let frames = take_until(&mut host, "hi", |f| has(&output(f), "hi"));
        assert!(has(&output(&frames), "hi\r\n"));
    }

    /// Output offsets are the running byte total after each frame, with no
    /// gap and no overlap (the host checks each frame), also over many frames.
    pub fn output_offsets_are_contiguous(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-offsets");
        host.write(b"flood 200\n").expect("write");
        let want = 200 * 1024;
        let frames = take_until(&mut host, "200 KiB", |f| output(f).len() >= want);
        assert!(frames.iter().filter(|f| matches!(f, FrameBody::Data { .. })).count() > 1);
        assert_eq!(last_offset(&frames), Some(output(&frames).len() as u64));
    }

    /// Output never passes the `out` credit: past one window it waits for
    /// the host's credit, then goes on where it stopped.
    pub fn output_waits_for_out_credit(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-credit");
        let window = host.terminal.window_bytes() as usize;
        host.grant = false;
        host.write(b"flood 600\n").expect("write");
        let first = take_until(&mut host, "one window", |f| output(f).len() >= window);
        assert_eq!(output(&first).len(), window, "no byte past the credit");
        assert!(output(&host.take()).is_empty(), "nothing more without credit");
        host.grant = true;
        host.consume();
        let rest = take_until(&mut host, "the rest", |f| output(f).len() >= 600 * 1024 - window);
        assert_eq!(output(&rest).len(), 600 * 1024 - window);
        assert_eq!(last_offset(&rest), Some(600 * 1024));
    }

    /// Input frames reach the far end in offset order; the backend grants
    /// `in` credit as it writes, so more than one window goes through.
    pub fn input_in_offset_order_reaches_the_far_end(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-order");
        let window = host.terminal.window_bytes() as usize;
        let total = 2 * window + 100;
        let want: Vec<u8> = (0..total).map(|i| b'a' + (i % 26) as u8).collect();
        for chunk in want.chunks(MAX_FRAME) {
            host.write(chunk).expect("within the `in` credit");
            host.take();
        }
        wait_far("every byte", || far.received().len() >= want.len());
        assert_eq!(far.received(), want);
    }

    /// A gap in the input offsets ends the terminal with `lost`, not retryable.
    pub fn an_input_gap_is_lost(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-gap");
        let offset = host.next_offset(2) + 1;
        host.push(FrameBody::Data { offset, bytes: b"ab".to_vec() }).expect("answered by end");
        let frames = take_until(&mut host, "lost", ended);
        assert_eq!(end(&frames), Some(&End::Lost(Lost::new("gap", false))));
        assert!(far.received().is_empty(), "nothing after a gap reaches the far end");
        assert!(not_open(host.write(b"late")));
    }

    /// An overlap (a repeated input frame) ends the terminal with `lost`.
    pub fn an_input_overlap_is_lost(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-overlap");
        host.write(b"ab").expect("write");
        host.push(FrameBody::Data { offset: 2, bytes: b"ab".to_vec() }).expect("answered by end");
        let frames = take_until(&mut host, "lost", ended);
        assert_eq!(end(&frames), Some(&End::Lost(Lost::new("overlap", false))));
        wait_far("the first frame", || far.received() == b"ab");
    }

    /// Credit for the wrong direction, or more than one window of `out`
    /// credit, ends the terminal with `lost`.
    pub fn bad_credit_is_lost(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-in-credit");
        let wrong = FrameBody::Credit { direction: Direction::In, bytes: 1 };
        host.push(wrong).expect("answered by end");
        let frames = take_until(&mut host, "lost", ended);
        assert_eq!(end(&frames), Some(&End::Lost(Lost::new("credit direction", false))));
        let mut host = open(far, "t-too-much");
        let too_much = FrameBody::Credit { direction: Direction::Out, bytes: 1 };
        host.push(too_much).expect("answered by end");
        let frames = take_until(&mut host, "lost", ended);
        assert_eq!(end(&frames), Some(&End::Lost(Lost::new("credit", false))));
    }

    /// The open size and every resize reach the far end.
    pub fn resize_reaches_far_end(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-resize");
        wait_far("the open grid", || far.grid() == Some((80, 24)));
        host.terminal.resize(Grid::new(132, 43)).expect("resize");
        wait_far("the new grid", || far.grid() == Some((132, 43)));
    }

    /// A signal reaches the far end by name.
    pub fn signal_reaches_far_end(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-signal");
        host.terminal.signal(Signal::Interrupt).expect("signal");
        wait_far("INT", || far.signals().iter().any(|s| s == "INT"));
    }

    /// A far-end exit gives `end` with the exit status after the last
    /// output, then nothing is accepted.
    pub fn far_exit_gives_exit_status(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-exit");
        host.write(b"echo bye\nexit 3\n").expect("write");
        let frames = take_until(&mut host, "exit", ended);
        let want = ExitStatus { code: Some(3), signal: None, core_dumped: false, message: None };
        assert_eq!(end(&frames), Some(&End::Exit(want)));
        assert!(matches!(frames.last(), Some(FrameBody::End(_))), "the end comes last");
        assert!(has(&output(&frames), "bye"), "the output before the exit: {frames:?}");
        assert!(not_open(host.write(b"late\n")));
        assert!(host.take().is_empty(), "nothing after the end");
    }

    /// A broken transport gives `lost {reason, retryable}`, never `exit`.
    pub fn transport_drop_gives_lost(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-lost");
        host.write(b"echo up\n").expect("write");
        take_until(&mut host, "up", |f| has(&output(f), "up"));
        far.drop_transport();
        let frames = take_until(&mut host, "lost", ended);
        assert!(
            matches!(frames.last(), Some(FrameBody::End(End::Lost(l))) if !l.reason.is_empty()),
            "{frames:?}"
        );
        assert!(not_open(host.write(b"late\n")));
    }

    /// After `close` every call is refused and nothing queues.
    pub fn close_refuses_later_calls(far: &mut dyn FarEnd) {
        let mut host = open(far, "t-close");
        host.terminal.close(Close::Graceful).expect("close");
        assert!(not_open(host.write(b"echo no\n")));
        assert!(not_open(host.terminal.resize(Grid::new(10, 10))));
        assert!(not_open(host.terminal.signal(Signal::Interrupt)));
        assert!(not_open(host.terminal.close(Close::Now)));
        let credit = FrameBody::Credit { direction: Direction::Out, bytes: 1 };
        assert!(not_open(host.push(credit)));
        assert!(host.take().is_empty());
    }
}

// --- The rescue backend over a fake transport that runs the tiny shell. ---

use cmux_cloud::rescue::{RESCUE_KIND, RescueBackend, RescueTransport, StreamId, TransportEvent};
use cmux_terminal_iface::{
    BackendError, ExitStatus, Grid, OpenRequest, OpenToken, Signal, TerminalBackend,
};
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
            open_token: OpenToken("open-token-test".into()),
            command: None,
            cwd: None,
            env: Vec::new(),
            grid,
            actor: None,
        }
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
fn rescue_output_waits_for_out_credit() {
    vectors::output_waits_for_out_credit(&mut far());
}

#[test]
fn rescue_input_in_offset_order_reaches_the_far_end() {
    vectors::input_in_offset_order_reaches_the_far_end(&mut far());
}

#[test]
fn rescue_an_input_gap_is_lost() {
    vectors::an_input_gap_is_lost(&mut far());
}

#[test]
fn rescue_an_input_overlap_is_lost() {
    vectors::an_input_overlap_is_lost(&mut far());
}

#[test]
fn rescue_bad_credit_is_lost() {
    vectors::bad_credit_is_lost(&mut far());
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
