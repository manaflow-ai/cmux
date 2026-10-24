//! A [`HolderService`] against a real holder, for the service's tests.
//!
//! The holder is the one this crate links (`cmux_holder::serve`), in a
//! process of its own: [`Holders::start`] runs this test binary again on
//! its `holder_process` fixture, which serves the holder socket until the
//! test kills it (a holder crash). Between the service and the holder sits
//! a [`Proxy`]: it records every frame each way and can end a connection at
//! an exact frame (a link that drops while the same holder lives on), so
//! each test drives the order it checks with frames, not with waits.

use std::io::{self, BufRead, BufReader, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_holder::wire::{self, Frame, Kind};

use super::super::HolderService;

/// The owner token of every test holder.
pub(super) const TOKEN: [u8; 32] = [0x3c; 32];

/// Names the socket the `holder_process` fixture serves; without it the
/// fixture returns at once (a normal test run).
pub(super) const HOLDER_SOCKET_ENV: &str = "CMUX_TEST_HOLDER_SOCKET";

/// The fixture's test path, as `--exact` takes it.
const HOLDER_PROCESS_TEST: &str = "holder_runtime::service::tests::holder_process";

/// How long a test waits for a frame or an output before it fails.
const DEADLINE: Duration = Duration::from_secs(20);

/// The holders one test started, all on one socket. The newest serves it.
pub(super) struct Holders {
    socket: PathBuf,
    started: Mutex<Vec<Child>>,
}

impl Holders {
    fn new(socket: PathBuf) -> Arc<Self> {
        Arc::new(Self { socket, started: Mutex::default() })
    }

    /// Start a holder on the socket and wait until it listens: the
    /// service's launcher.
    pub(super) fn start(&self, token: &[u8; 32]) -> io::Result<()> {
        let mut child = Command::new(std::env::current_exe()?)
            .args([HOLDER_PROCESS_TEST, "--exact", "--nocapture", "--quiet"])
            .env(HOLDER_SOCKET_ENV, &self.socket)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let hex: String = token.iter().map(|byte| format!("{byte:02x}")).collect();
        let started = child
            .stdin
            .take()
            .ok_or_else(|| io::Error::other("no holder stdin"))
            .and_then(|mut stdin| stdin.write_all(format!("{hex}\n").as_bytes()));
        let ready = started.and_then(|()| {
            let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no holder stdout"))?;
            // The test harness prints its own lines (`running 1 test`) first.
            for line in BufReader::new(stdout).lines() {
                if line?.trim() == "ready" {
                    return Ok(());
                }
            }
            Err(io::Error::other("the test holder ended before it listened"))
        });
        if let Err(error) = ready {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
        self.started.lock().unwrap().push(child);
        Ok(())
    }

    /// SIGKILL the holder that serves the socket (a holder crash).
    pub(super) fn crash(&self) {
        let mut holder = self.started.lock().unwrap().pop().expect("a holder runs");
        let _ = holder.kill();
        let _ = holder.wait();
    }

    fn kill_all(&self) {
        for mut holder in self.started.lock().unwrap().drain(..) {
            let _ = holder.kill();
            let _ = holder.wait();
        }
    }
}

/// One frame the proxy passed or cut.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Seen {
    /// The service's connection that reached a holder, counting from 1.
    pub(super) conn: usize,
    /// Daemon to holder (else holder to daemon).
    pub(super) to_holder: bool,
    pub(super) kind: Option<Kind>,
    pub(super) chan: u32,
}

impl Seen {
    /// A daemon frame of `kind` for `chan`.
    pub(super) fn sent(&self, kind: Kind, chan: u32) -> bool {
        self.to_holder && self.kind == Some(kind) && self.chan == chan
    }
}

/// What the proxy does with a frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Verdict {
    Forward,
    /// End the connection both ways instead of passing the frame: the
    /// service sees its link lost, the holder sees its daemon go.
    Cut,
}

type Rule = Box<dyn Fn(&Seen) -> Verdict + Send + Sync>;

/// Shared by the proxy's threads.
struct ProxyState {
    rule: Mutex<Rule>,
    /// Both sockets of each connection, to cut it.
    connections: Mutex<Vec<(UnixStream, UnixStream)>>,
    stopped: AtomicBool,
}

/// The service's socket: each connection reaches the holder socket, frame
/// by frame.
pub(super) struct Proxy {
    socket: PathBuf,
    state: Arc<ProxyState>,
    seen: Receiver<Seen>,
}

impl Proxy {
    fn start(socket: &Path, holder: &Path) -> Self {
        let listener = UnixListener::bind(socket).unwrap();
        let state = Arc::new(ProxyState {
            rule: Mutex::new(Box::new(|_: &Seen| Verdict::Forward)),
            connections: Mutex::default(),
            stopped: AtomicBool::new(false),
        });
        let (record, seen) = channel();
        let accepting = state.clone();
        let holder = holder.to_path_buf();
        std::thread::spawn(move || {
            let mut connections = 0;
            for daemon in listener.incoming() {
                if accepting.stopped.load(Ordering::Acquire) {
                    return;
                }
                let Ok(daemon) = daemon else { return };
                // No holder listens: the daemon's connect fails as it would
                // without the proxy (its handshake reads end of file).
                let Ok(upstream) = UnixStream::connect(&holder) else { continue };
                connections += 1;
                let conn = connections;
                let pair = (daemon.try_clone().unwrap(), upstream.try_clone().unwrap());
                accepting.connections.lock().unwrap().push(pair);
                for to_holder in [true, false] {
                    let (from, to) =
                        if to_holder { (&daemon, &upstream) } else { (&upstream, &daemon) };
                    let (from, to) = (from.try_clone().unwrap(), to.try_clone().unwrap());
                    let (state, record) = (accepting.clone(), record.clone());
                    std::thread::spawn(move || relay(from, to, conn, to_holder, &state, &record));
                }
            }
        });
        Self { socket: socket.to_path_buf(), state, seen }
    }

    /// Decide every frame from now on with `rule`.
    pub(super) fn set_rule(&self, rule: impl Fn(&Seen) -> Verdict + Send + Sync + 'static) {
        *self.state.rule.lock().unwrap() = Box::new(rule);
    }

    /// End every connection now (a link drop; the holder lives on).
    pub(super) fn cut(&self) {
        for (daemon, holder) in self.state.connections.lock().unwrap().drain(..) {
            let _ = daemon.shutdown(std::net::Shutdown::Both);
            let _ = holder.shutdown(std::net::Shutdown::Both);
        }
    }

    /// The frames from the last one returned through the first that
    /// matches `wanted`; fails the test when none comes in time.
    pub(super) fn frames_until(&self, what: &str, wanted: impl Fn(&Seen) -> bool) -> Vec<Seen> {
        let deadline = Instant::now() + DEADLINE;
        let mut frames = Vec::new();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            match self.seen.recv_timeout(left) {
                Ok(seen) => {
                    frames.push(seen);
                    if wanted(&seen) {
                        return frames;
                    }
                }
                Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => {
                    panic!("no frame for {what}; the frames since the last one: {frames:?}")
                }
            }
        }
    }

    /// The first frame that matches `wanted` ([`Self::frames_until`]).
    pub(super) fn wait_for(&self, what: &str, wanted: impl Fn(&Seen) -> bool) -> Seen {
        *self.frames_until(what, wanted).last().unwrap()
    }
}

impl Drop for Proxy {
    fn drop(&mut self) {
        self.state.stopped.store(true, Ordering::Release);
        // Wakes the accept loop, which sees it stopped.
        let _ = UnixStream::connect(&self.socket);
        self.cut();
    }
}

/// Pass frames from `from` to `to` until either side ends or the rule cuts.
fn relay(
    from: UnixStream,
    to: UnixStream,
    conn: usize,
    to_holder: bool,
    state: &ProxyState,
    record: &Sender<Seen>,
) {
    let mut reader = wire::Reader::default();
    loop {
        loop {
            let frame = match reader.next_frame() {
                Ok(Some(frame)) => frame,
                Ok(None) => break,
                Err(_) => return end(&from, &to),
            };
            let seen = Seen { conn, to_holder, kind: Kind::from_u16(frame.kind), chan: frame.chan };
            let verdict = {
                let rule = state.rule.lock().unwrap();
                (**rule)(&seen)
            };
            let _ = record.send(seen);
            if verdict == Verdict::Cut || forward(to.as_raw_fd(), frame).is_err() {
                return end(&from, &to);
            }
        }
        if !matches!(reader.fill(from.as_raw_fd()), Ok(true)) {
            return end(&from, &to);
        }
    }
}

/// Write `frame` as it came: its kind flags, its descriptors with its
/// first byte.
fn forward(to: RawFd, frame: Frame) -> io::Result<()> {
    let kind = Kind::from_u16(frame.kind).ok_or_else(|| io::Error::other("unknown frame kind"))?;
    // The bits under the stated count are the kind's own flags.
    let flags = frame.flags & (wire::FLAG_FDS_STATED - 1);
    let bytes = wire::encode_with_fds(kind, flags, frame.chan, &frame.payload, frame.fds.len());
    let fds: Vec<RawFd> = frame.fds.iter().map(AsRawFd::as_raw_fd).collect();
    wire::send_all(to, &bytes, &fds)
}

fn end(from: &UnixStream, to: &UnixStream) {
    let _ = from.shutdown(std::net::Shutdown::Both);
    let _ = to.shutdown(std::net::Shutdown::Both);
}

/// A service whose socket is a [`Proxy`] to the holders a test starts.
pub(super) struct World {
    dir: PathBuf,
    holder_socket: PathBuf,
    pub(super) holders: Arc<Holders>,
    pub(super) proxy: Proxy,
    pub(super) service: Arc<HolderService>,
}

impl World {
    /// No holder runs yet: the service starts one when a spawn or a restart
    /// needs a link, or the test does.
    pub(super) fn new() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!(
            "cmhs-{}-{}",
            std::process::id(),
            stamp % 1_000_000_000
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let holder_socket = dir.join("h.sock");
        let daemon_socket = dir.join("d.sock");
        let holders = Holders::new(holder_socket.clone());
        let proxy = Proxy::start(&daemon_socket, &holder_socket);
        let launch = holders.clone();
        let service = HolderService::new(
            daemon_socket,
            TOKEN,
            Box::new(move |_socket: &Path, token: &[u8; 32]| launch.start(token)),
        );
        Self { dir, holder_socket, holders, proxy, service }
    }

    /// The holder's own socket (a previous daemon's, bypassing the proxy).
    pub(super) fn holder_socket(&self) -> &Path {
        &self.holder_socket
    }
}

impl Drop for World {
    fn drop(&mut self) {
        self.holders.kill_all();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
