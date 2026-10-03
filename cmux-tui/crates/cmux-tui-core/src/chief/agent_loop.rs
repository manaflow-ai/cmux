//! The hub connection loop (one thread for the life of the Chief): connect,
//! run the connect sequence under one deadline, hand the connection to the
//! actor, wait until it closes, wait the backoff, again. The TypeScript
//! host's `loop("acpmux")` and `runAcpmux`.

use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::HostState;

use super::actor::Msg;
use super::agent::{
    self, AgentConnection, AgentConnector, AgentNotice, Backoff, NoticeGate, SessionSpec,
};

/// What the loop thread waits for.
pub(super) enum Ctl {
    /// Connection `id` ended.
    Closed(u64),
    Stop,
}

/// The loop's settings.
pub(super) struct AgentLoop {
    pub(super) connector: Arc<dyn AgentConnector>,
    pub(super) spec: SessionSpec,
    pub(super) shared: Arc<Mutex<HostState>>,
    pub(super) sender: Sender<Msg>,
    pub(super) ctl: Sender<Ctl>,
    pub(super) ctl_rx: Receiver<Ctl>,
    /// The connection being set up or running, so a stop can close it.
    pub(super) current: Arc<Mutex<Option<Arc<dyn AgentConnection>>>>,
    pub(super) timeout: Duration,
    pub(super) backoff: Backoff,
    pub(super) log: Arc<dyn Fn(&str) + Send + Sync>,
}

pub(super) fn spawn(settings: AgentLoop) -> std::io::Result<std::thread::JoinHandle<()>> {
    std::thread::Builder::new().name("chief-acpmux".into()).spawn(move || run(&settings))
}

enum End {
    Stopped,
    Closed { lived: Duration },
}

/// A connection that lived longer than the backoff maximum starts the
/// backoff over; one that came up and closed at once keeps growing it.
fn run(settings: &AgentLoop) {
    let mut delay = settings.backoff.initial;
    let mut id = 0;
    loop {
        id += 1;
        match run_once(settings, id) {
            Ok(End::Stopped) => return,
            Ok(End::Closed { lived }) => {
                (settings.log)("acpmux connection closed");
                if lived > settings.backoff.max {
                    delay = settings.backoff.initial;
                }
            }
            Err(error) => (settings.log)(&format!("acpmux: {error:#}")),
        }
        *settings.current.lock().unwrap() = None;
        if wait_backoff(settings, delay) {
            return;
        }
        delay = (delay * 2).min(settings.backoff.max);
    }
}

/// Waits `delay` unless a stop comes first (true). Stale close notices of
/// older connections are skipped.
fn wait_backoff(settings: &AgentLoop, delay: Duration) -> bool {
    let until = Instant::now() + delay;
    loop {
        match settings.ctl_rx.recv_timeout(until.saturating_duration_since(Instant::now())) {
            Ok(Ctl::Stop) | Err(RecvTimeoutError::Disconnected) => return true,
            Ok(Ctl::Closed(_)) => {}
            Err(RecvTimeoutError::Timeout) => return false,
        }
    }
}

fn run_once(settings: &AgentLoop, id: u64) -> anyhow::Result<End> {
    let gate = NoticeGate::new();
    let forward = forwarder(settings.sender.clone(), settings.ctl.clone(), id);
    let (sink_gate, sink_forward) = (gate.clone(), forward.clone());
    let connection = settings.connector.connect(Box::new(move |notice| {
        if let Some(notice) = sink_gate.hold(notice) {
            sink_forward(notice);
        }
    }))?;
    *settings.current.lock().unwrap() = Some(connection.clone());
    let deadline = Instant::now() + settings.timeout;
    let state = settings.shared.lock().unwrap().clone();
    let input = match agent::connect_sequence(&connection, &settings.spec, &state, deadline) {
        Ok(input) => input,
        Err(error) => {
            connection.close();
            return Err(error);
        }
    };
    let up = Instant::now();
    let _ = settings.sender.send(Msg::AgentUp { id, connection: connection.clone(), input });
    gate.open(|notice| forward(notice));
    let stopped = wait_for_end(settings, id, &connection);
    let _ = settings.sender.send(Msg::AgentDown { id });
    Ok(if stopped { End::Stopped } else { End::Closed { lived: up.elapsed() } })
}

/// Blocks until connection `id` closes (false) or the Chief stops (true).
fn wait_for_end(settings: &AgentLoop, id: u64, connection: &Arc<dyn AgentConnection>) -> bool {
    loop {
        match settings.ctl_rx.recv() {
            Ok(Ctl::Stop) | Err(_) => {
                connection.close();
                return true;
            }
            Ok(Ctl::Closed(closed)) if closed == id => return false,
            Ok(Ctl::Closed(_)) => {}
        }
    }
}

fn forwarder(
    sender: Sender<Msg>,
    ctl: Sender<Ctl>,
    id: u64,
) -> Arc<dyn Fn(AgentNotice) + Send + Sync> {
    let ctl = Mutex::new(ctl);
    Arc::new(move |notice| match notice {
        AgentNotice::Closed => {
            let _ = ctl.lock().unwrap().send(Ctl::Closed(id));
        }
        AgentNotice::Notification { method, params } => {
            if let Some(input) = agent::notice_input(&method, &params) {
                let _ = sender.send(Msg::AgentInput { id, input });
            }
        }
    })
}
