//! Fakes for the attach tests: a link spawner that starts no process and a
//! rescue transport that reaches no machine.

#![allow(dead_code)]

use cmux_cloud::app_env::AppEnv;
use cmux_cloud::connector::iface::CarrierEvent;
use cmux_cloud::link::{
    Attach, LinkCommand, LinkEvents, LinkPaths, LinkProcess, LinkProcessEvent, LinkSpawner, LinkTag,
};
use cmux_cloud::rescue::iface::{BackendError, Grid, Signal};
use cmux_cloud::rescue::{RescueTransport, StreamId, TransportEvent};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// What the next spawned link does right away.
#[derive(Debug, Clone)]
pub enum Script {
    /// Prints `connection-snapshot` with this socket.
    Ready,
    /// Exits with this code before it is ready.
    ExitEarly(i32),
    /// Prints nothing until [`FakeSpawner::ready`]; sends its tag on the
    /// channel once spawned.
    Hold(std::sync::mpsc::Sender<LinkTag>),
}

#[derive(Default)]
pub struct SpawnLog {
    pub commands: Vec<LinkCommand>,
    pub tags: Vec<LinkTag>,
    pub senders: Vec<LinkEvents>,
    pub terminated: Vec<LinkTag>,
    pub script: VecDeque<Script>,
}

#[derive(Clone, Default)]
pub struct FakeSpawner(pub Arc<Mutex<SpawnLog>>);

impl FakeSpawner {
    pub fn log(&self) -> std::sync::MutexGuard<'_, SpawnLog> {
        self.0.lock().unwrap()
    }

    pub fn spawns(&self) -> usize {
        self.log().commands.len()
    }

    /// The last link process of `machine` prints its ready line.
    pub fn ready(&self, machine: &str) {
        let log = self.log();
        let index = log.tags.iter().rposition(|t| t.machine == machine).expect("spawned");
        let tag = log.tags[index].clone();
        let ready =
            serde_json::json!({ "event": "carrier-ready", "local_socket": socket_for(&tag) });
        log.senders[index].send(LinkProcessEvent::Line { tag, line: ready.to_string() }).unwrap();
    }

    /// A stream of the last carrier of `machine` is refused with this
    /// `link.dial` error code (as the real carrier reports it).
    pub fn refuse(&self, machine: &str, code: &str) {
        let log = self.log();
        let index = log.tags.iter().rposition(|t| t.machine == machine).expect("spawned");
        let failed = serde_json::json!({ "event": "dial-failed", "error_code": code });
        log.senders[index]
            .send(LinkProcessEvent::Line { tag: log.tags[index].clone(), line: failed.to_string() })
            .unwrap();
    }

    /// The last link process of `machine` exits with `code`.
    pub fn exit(&self, machine: &str, code: i32) {
        let log = self.log();
        let index = log.tags.iter().rposition(|t| t.machine == machine).expect("spawned");
        log.senders[index]
            .send(LinkProcessEvent::Exited { tag: log.tags[index].clone(), code: Some(code) })
            .unwrap();
    }
}

struct FakeProcess {
    tag: LinkTag,
    log: Arc<Mutex<SpawnLog>>,
}

impl LinkProcess for FakeProcess {
    fn pid(&self) -> Option<u32> {
        None
    }

    fn terminate(&mut self) {
        self.log.lock().unwrap().terminated.push(self.tag.clone());
    }
}

pub fn socket_for(tag: &LinkTag) -> String {
    format!("/tmp/cmux-test/{}-{}.sock", tag.machine, tag.generation)
}

impl LinkSpawner for FakeSpawner {
    fn spawn(
        &mut self,
        tag: LinkTag,
        command: &LinkCommand,
        events: LinkEvents,
    ) -> std::io::Result<Box<dyn LinkProcess>> {
        let mut log = self.0.lock().unwrap();
        log.commands.push(command.clone());
        log.tags.push(tag.clone());
        log.senders.push(events.clone());
        let line = |l: &str| LinkProcessEvent::Line { tag: tag.clone(), line: l.to_owned() };
        match log.script.pop_front().unwrap_or(Script::Ready) {
            Script::Ready => {
                events.send(line(r#"{"event":"starting"}"#)).unwrap();
                let ready = serde_json::json!({
                    "event": "carrier-ready",
                    "local_socket": socket_for(&tag),
                });
                events.send(line(&ready.to_string())).unwrap();
            }
            Script::ExitEarly(code) => {
                events
                    .send(LinkProcessEvent::Exited { tag: tag.clone(), code: Some(code) })
                    .unwrap();
            }
            Script::Hold(spawned) => {
                let _ = spawned.send(tag.clone());
            }
        }
        Ok(Box::new(FakeProcess { tag, log: Arc::clone(&self.0) }))
    }
}

pub fn paths() -> LinkPaths {
    LinkPaths {
        binary: PathBuf::from("/opt/cmux/bin/cmux-tui"),
        hub_socket: PathBuf::from("/tmp/cmux-test/wg-hub.sock"),
        state_dir: PathBuf::from("/tmp/cmux-test/link-state"),
        socket_dir: PathBuf::from("/tmp/cmux-test"),
        device_name: "test-mac".into(),
    }
}

#[derive(Default)]
pub struct TransportLog {
    pub opened: Vec<(String, Grid)>,
    pub writes: Vec<(StreamId, Vec<u8>)>,
    pub resizes: Vec<(StreamId, Grid)>,
    pub signals: Vec<(StreamId, Signal)>,
    pub closes: Vec<StreamId>,
    pub events: Vec<(StreamId, TransportEvent)>,
    /// Every write fails as if the network dropped.
    pub fail_writes: bool,
    next: StreamId,
}

#[derive(Clone, Default)]
pub struct FakeTransport(pub Arc<Mutex<TransportLog>>);

impl FakeTransport {
    pub fn log(&self) -> std::sync::MutexGuard<'_, TransportLog> {
        self.0.lock().unwrap()
    }

    pub fn emit(&self, stream: StreamId, event: TransportEvent) {
        self.log().events.push((stream, event));
    }

    pub fn written(&self, stream: StreamId) -> Vec<u8> {
        self.log()
            .writes
            .iter()
            .filter(|(s, _)| *s == stream)
            .flat_map(|(_, b)| b.clone())
            .collect()
    }
}

impl RescueTransport for FakeTransport {
    fn open(&mut self, machine: &str, grid: Grid) -> Result<StreamId, BackendError> {
        let mut log = self.log();
        log.opened.push((machine.to_owned(), grid));
        log.next += 1;
        Ok(log.next)
    }

    fn write(&mut self, stream: StreamId, bytes: &[u8]) -> Result<(), BackendError> {
        let mut log = self.log();
        if log.fail_writes {
            return Err(BackendError::Unavailable {
                reason: "the network dropped".into(),
                retryable: true,
            });
        }
        log.writes.push((stream, bytes.to_vec()));
        Ok(())
    }

    fn resize(&mut self, stream: StreamId, grid: Grid) -> Result<(), BackendError> {
        self.log().resizes.push((stream, grid));
        Ok(())
    }

    fn signal(&mut self, stream: StreamId, signal: Signal) -> Result<(), BackendError> {
        self.log().signals.push((stream, signal));
        Ok(())
    }

    fn close(&mut self, stream: StreamId) -> Result<(), BackendError> {
        self.log().closes.push(stream);
        Ok(())
    }

    fn take_events(&mut self) -> Vec<(StreamId, TransportEvent)> {
        std::mem::take(&mut self.log().events)
    }
}

/// Link events of the server's supervisor since the last call (what the
/// serve loop sends as `cloud.link.changed`).
pub fn link_events<C: cmux_cloud::ControlPlane>(
    server: &mut cmux_cloud::Server<C>,
) -> Vec<CarrierEvent> {
    server.take_link_events()
}

/// An app environment with its own data folder under the test temp
/// folder (one per call).
pub fn test_env() -> AppEnv {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let data = std::env::temp_dir().join(format!("cmux-cloud-data-{}-{n}", std::process::id()));
    AppEnv::from_vars([
        ("CMUX_APP_ID", "cmux/cloud"),
        ("CMUX_APP_DATA_DIR", data.to_str().unwrap()),
    ])
}

/// Attach with the fake spawner, test paths, the fake transport and a
/// test app environment.
pub fn attach(spawner: &FakeSpawner, transport: &FakeTransport) -> Attach {
    Attach::new(Box::new(spawner.clone()), Some(paths()), Box::new(transport.clone()))
        .with_env(test_env())
}

/// A clock the test fires by hand: `after` records the callback, a dropped
/// timer marks it cancelled.
#[derive(Clone, Default)]
pub struct ManualClock(Arc<Mutex<Vec<ManualTimer>>>);

/// A recorded timer: still live (not cancelled), and its callback.
type ManualTimer = (Arc<std::sync::atomic::AtomicBool>, Option<Box<dyn FnOnce() + Send>>);

impl ManualClock {
    /// Fires every timer that was not cancelled; returns how many fired.
    pub fn fire_all(&self) -> usize {
        let timers: Vec<_> = std::mem::take(&mut *self.0.lock().unwrap());
        let mut fired = 0;
        for (live, fire) in timers {
            if live.load(std::sync::atomic::Ordering::SeqCst)
                && let Some(fire) = fire
            {
                fire();
                fired += 1;
            }
        }
        fired
    }
}

impl cmux_cloud::clock::Clock for ManualClock {
    fn after(
        &self,
        _delay: std::time::Duration,
        fire: Box<dyn FnOnce() + Send>,
    ) -> cmux_cloud::clock::Timer {
        let live = Arc::new(std::sync::atomic::AtomicBool::new(true));
        self.0.lock().unwrap().push((Arc::clone(&live), Some(fire)));
        cmux_cloud::clock::Timer::new(Box::new(move || {
            live.store(false, std::sync::atomic::Ordering::SeqCst);
        }))
    }
}
