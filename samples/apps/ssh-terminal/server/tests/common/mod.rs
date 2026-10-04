//! Test harness: an in-memory fake of the host's `connection.channel.*`
//! ops. No network, no SSH, no key: the fake stands for the host, which
//! owns the SSH transport, the pinned host keys and the user's credential.
//!
//! Each channel runs a tiny shell on its input:
//! - `echo X` answers `X\r\n`;
//! - `exit N` ends the channel with exit status N;
//! - `flood N` answers N KiB of `f`;
//! - `die SIG` ends the channel with exit signal SIG, a core dump and a
//!   5000-byte message.
//!
//! Every other line is only recorded.

#![allow(dead_code)]

use ssh_terminal::iface::{
    BackendError, ByteEvent, ByteTerminal, ChannelEvent, ChannelId, ChannelOpenRequest, ExitStatus,
    Grid, HostChannels, HostKeyRefusal, OpenRequest, OpenToken, Signal,
};
use ssh_terminal::{SSH_KIND, SshBackend};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

pub const HANDLE: &str = "conn_test";
pub const FINGERPRINT: &str = "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU";
const WAIT: Duration = Duration::from_secs(10);
const TICK: Duration = Duration::from_millis(5);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trust {
    /// The user pinned the server's key for the handle.
    Known,
    /// No key is pinned for the handle.
    Unknown,
    /// A different key is pinned for the handle.
    Changed,
}

/// What the fake host saw, in order.
#[derive(Debug, Clone, Default)]
pub struct HostLog {
    /// Every host op the backend called, by name.
    pub ops: Vec<&'static str>,
    /// Every `connection.channel.open` request that reached the host.
    pub opens: Vec<ChannelOpenRequest>,
    /// Channels the host opened (after the host key check).
    pub channels: usize,
    /// Input bytes that reached a far shell, in arrival order.
    pub input: Vec<u8>,
    /// The PTY size, then each window change.
    pub grids: Vec<(u16, u16)>,
    pub signals: Vec<String>,
    pub closes: usize,
}

#[derive(Default)]
struct FakeChannel {
    out: VecDeque<u8>,
    end: Option<ChannelEvent>,
    end_sent: bool,
    line: Vec<u8>,
    closed: bool,
}

#[derive(Default)]
struct State {
    log: HostLog,
    issued: HashSet<String>,
    next_token: u64,
    next_channel: u64,
    channels: HashMap<String, FakeChannel>,
    /// While set, `send` answers that the host buffer is full.
    stalled: bool,
}

pub struct FakeHost {
    trust: Trust,
    state: Mutex<State>,
}

impl FakeHost {
    pub fn new(trust: Trust) -> Arc<Self> {
        Arc::new(Self { trust, state: Mutex::new(State::default()) })
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// A fresh `open_token`, as the host issues it after a user gesture.
    pub fn issue_token(&self) -> OpenToken {
        let mut state = self.state();
        state.next_token += 1;
        let token = format!("otk-{}", state.next_token);
        state.issued.insert(token.clone());
        OpenToken(token)
    }

    pub fn log(&self) -> HostLog {
        self.state().log.clone()
    }

    pub fn stall_input(&self, stalled: bool) {
        self.state().stalled = stalled;
    }

    /// Ends every open channel with no exit (the TCP link died).
    pub fn drop_transport(&self) {
        for channel in self.state().channels.values_mut() {
            if channel.end.is_none() {
                channel.end = Some(ChannelEvent::Dropped {
                    reason: "the ssh connection ended".into(),
                    retryable: true,
                });
            }
        }
    }

    pub fn wait_for(&self, what: &str, check: impl Fn(&HostLog) -> bool) -> HostLog {
        let deadline = Instant::now() + WAIT;
        loop {
            let log = self.log();
            if check(&log) {
                return log;
            }
            assert!(Instant::now() < deadline, "the host never saw {what}: {log:?}");
            std::thread::sleep(TICK);
        }
    }
}

fn run_line(channel: &mut FakeChannel) {
    let line = String::from_utf8_lossy(&std::mem::take(&mut channel.line)).into_owned();
    if let Some(text) = line.strip_prefix("echo ") {
        channel.out.extend(format!("{text}\r\n").bytes());
    } else if let Some(kib) = line.strip_prefix("flood ") {
        let kib: usize = kib.trim().parse().unwrap_or(0);
        channel.out.extend(std::iter::repeat_n(b'f', kib * 1024));
    } else if let Some(code) = line.strip_prefix("exit ") {
        let code = code.trim().parse().unwrap_or(1);
        channel.end =
            Some(ChannelEvent::Exit(ExitStatus { code: Some(code), ..Default::default() }));
    } else if let Some(signal) = line.strip_prefix("die ") {
        channel.end = Some(ChannelEvent::Exit(ExitStatus {
            code: None,
            signal: Some(signal.trim().to_owned()),
            core_dumped: true,
            message: Some("m".repeat(5000)),
        }));
    }
}

fn channel<'a>(state: &'a mut State, id: &ChannelId) -> Result<&'a mut FakeChannel, BackendError> {
    match state.channels.get_mut(&id.0) {
        Some(channel) if !channel.closed => Ok(channel),
        _ => Err(BackendError::invalid("no such channel")),
    }
}

impl HostChannels for FakeHost {
    fn open(&self, request: ChannelOpenRequest) -> Result<ChannelId, BackendError> {
        let mut state = self.state();
        state.log.ops.push("open");
        state.log.opens.push(request.clone());
        // One token per open: a missing, unknown or reused token is refused.
        if !state.issued.remove(&request.open_token.0) {
            return Err(BackendError::Denied { reason: "open_token refused".into() });
        }
        if request.connection != HANDLE {
            return Err(BackendError::Denied { reason: "unknown connection handle".into() });
        }
        // The host checks the pinned key during key exchange, before auth
        // and before any channel: no byte reaches the shell.
        let decision = match self.trust {
            Trust::Known => None,
            Trust::Unknown => Some(HostKeyRefusal::Unknown),
            Trust::Changed => Some(HostKeyRefusal::Changed),
        };
        if let Some(decision) = decision {
            return Err(BackendError::HostKey { decision, fingerprint: FINGERPRINT.into() });
        }
        state.next_channel += 1;
        let id = format!("ch-{}", state.next_channel);
        state.channels.insert(id.clone(), FakeChannel::default());
        state.log.channels += 1;
        state.log.grids.push((request.pty.cols, request.pty.rows));
        Ok(ChannelId(id))
    }

    fn resize(&self, id: &ChannelId, cols: u16, rows: u16) -> Result<(), BackendError> {
        let mut state = self.state();
        state.log.ops.push("resize");
        channel(&mut state, id)?;
        state.log.grids.push((cols, rows));
        Ok(())
    }

    fn signal(&self, id: &ChannelId, signal: Signal) -> Result<(), BackendError> {
        let mut state = self.state();
        state.log.ops.push("signal");
        channel(&mut state, id)?;
        state.log.signals.push(signal.name().to_owned());
        Ok(())
    }

    fn close(&self, id: &ChannelId) -> Result<(), BackendError> {
        let mut state = self.state();
        state.log.ops.push("close");
        channel(&mut state, id)?.closed = true;
        state.log.closes += 1;
        Ok(())
    }

    fn send(&self, id: &ChannelId, bytes: &[u8]) -> Result<(), BackendError> {
        let mut state = self.state();
        if state.stalled {
            return Err(BackendError::Unavailable {
                reason: "the host buffer is full".into(),
                retryable: true,
            });
        }
        let ended = channel(&mut state, id)?.end.is_some();
        if ended {
            return Err(BackendError::invalid("the channel ended"));
        }
        state.log.input.extend_from_slice(bytes);
        let channel = channel(&mut state, id)?;
        for &byte in bytes {
            if channel.end.is_some() {
                break;
            }
            if byte == b'\n' || byte == b'\r' {
                run_line(channel);
            } else {
                channel.line.push(byte);
            }
        }
        Ok(())
    }

    fn receive(&self, id: &ChannelId, max_bytes: usize) -> Vec<ChannelEvent> {
        let mut state = self.state();
        let Ok(channel) = channel(&mut state, id) else { return Vec::new() };
        let mut events = Vec::new();
        let take = channel.out.len().min(max_bytes);
        if take > 0 {
            events.push(ChannelEvent::Data(channel.out.drain(..take).collect()));
        }
        if channel.out.is_empty()
            && !channel.end_sent
            && let Some(end) = channel.end.clone()
        {
            events.push(end);
            channel.end_sent = true;
        }
        events
    }
}

pub struct Fixture {
    pub host: Arc<FakeHost>,
    pub backend: SshBackend,
}

pub fn fixture(trust: Trust) -> Fixture {
    let host = FakeHost::new(trust);
    let backend = SshBackend::new(host.clone()).expect("backend");
    Fixture { host, backend }
}

pub fn request(host: &FakeHost, kind: &str, terminal: &str, grid: Grid) -> OpenRequest {
    OpenRequest {
        kind: kind.into(),
        terminal: terminal.into(),
        target: HANDLE.into(),
        open_token: host.issue_token(),
        command: None,
        cwd: None,
        env: Vec::new(),
        grid,
        actor: None,
    }
}

pub fn ssh_request(f: &Fixture, terminal: &str) -> OpenRequest {
    request(&f.host, SSH_KIND, terminal, Grid::new(80, 24))
}

/// Drains events until `done` holds for everything taken so far.
pub fn events_until(
    terminal: &mut dyn ByteTerminal,
    what: &str,
    done: impl Fn(&[ByteEvent]) -> bool,
) -> Vec<ByteEvent> {
    let deadline = Instant::now() + WAIT;
    let mut all = Vec::new();
    loop {
        all.extend(terminal.take_events());
        if done(&all) {
            return all;
        }
        assert!(Instant::now() < deadline, "never saw {what}: {all:?}");
        std::thread::sleep(TICK);
    }
}

/// All output bytes in `events`, joined.
pub fn output(events: &[ByteEvent]) -> Vec<u8> {
    events
        .iter()
        .filter_map(|e| match e {
            ByteEvent::Output { bytes, .. } => Some(bytes.as_slice()),
            _ => None,
        })
        .flatten()
        .copied()
        .collect()
}

pub fn contains(haystack: &[u8], needle: &str) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle.as_bytes())
}

pub fn is_end(event: &ByteEvent) -> bool {
    matches!(event, ByteEvent::Exit(_) | ByteEvent::Lost { .. })
}
