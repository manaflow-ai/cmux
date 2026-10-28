//! Energy Saver reaches this machine's acpmux. The daemon's
//! mode ([`crate::server::energy_op::DaemonEnergy::mode`], which the app's
//! `energy.set` and the daemon's own reading flip) goes to acpmux as
//! `_acpmux/energy {saver}` on the agent chat watch's connection
//! (`agent_chat_notices.rs`): the current value each time the watch reaches
//! acpmux, so an acpmux that starts or restarts in Energy Saver learns it,
//! then once per edge. acpmux stretches its skippable maintenance jobs from
//! it (`acpmux/src/energy_control.rs`). Chrome tells each child process the
//! same way: one `SetBatterySaverMode` per edge, and the current mode to a
//! child as it starts
//! (chrome/browser/performance_manager/public/user_tuning/battery_saver_mode_manager.h).
//!
//! The app's memory limit (`memory.limit`, server/memory_limit.rs) goes the
//! same way as `_acpmux/memory_limit {level, mode, override}`
//! (`acpmux/src/memory_control.rs`): the limit the app holds as the watch
//! connects, then each change, `level: null` once the app's limit went with
//! its connection. acpmux votes it next to its own kernel source, as
//! Chrome's `ChildMemoryConsumerRegistryHost` hands a child the browser's
//! limit (content/browser/memory_coordinator/README.md).
//!
//! The mode's watcher and the memory relay only queue a change for the
//! `mux-acpmux-energy` thread, which does the write, so `energy.set` and
//! `memory.limit` stay a store and a notify. The thread waits on its channel
//! with no timeout: no wake while nothing changes. Its replies come back on
//! the watch's connection, which reads past them.

use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Weak};
use std::time::Duration;

use cmux_threads::ThreadQos;
use serde_json::{Value, json};

use crate::memory::DaemonMemory;
use crate::server::memory_limit::WireLevel;
use crate::supervised::{self, Fatal, ShutdownBehavior};
use crate::wake::{EnergyMode, EnergyWatch};

/// acpmux's Energy Saver method (`acpmux/src/rpc.rs`, `MUX_ENERGY`).
pub(super) const METHOD: &str = "_acpmux/energy";
/// acpmux's memory limit method (`acpmux/src/rpc.rs`, `MUX_MEMORY_LIMIT`).
pub(super) const MEMORY_METHOD: &str = "_acpmux/memory_limit";
const THREAD_NAME: &str = "mux-acpmux-energy";
/// A write acpmux does not take within this long ends the relay's link.
const WRITE_TIMEOUT: Duration = Duration::from_secs(3);

enum Relay {
    /// The watch reached acpmux: this is a writer on its connection.
    Reached(UnixStream),
    /// The mode changed.
    Edge,
    /// The app's memory limit changed.
    MemoryLimit,
}

/// The relay thread's inbox and the mode watch that feeds it. Dropping it
/// ends the thread.
pub(super) struct AcpmuxEnergy {
    /// The memory relay holds it weakly, so dropping this ends the thread.
    inbox: Arc<Sender<Relay>>,
    _watch: EnergyWatch,
}

impl AcpmuxEnergy {
    /// Starts the relay thread for `mode` and the app's limit in `memory`.
    pub(super) fn start(mode: &Arc<EnergyMode>, memory: &Arc<DaemonMemory>) -> io::Result<Self> {
        let (inbox, relay) = mpsc::channel();
        let inbox = Arc::new(inbox);
        let edges = Sender::clone(&inbox);
        let watch = mode.watch(move || {
            let _ = edges.send(Relay::Edge);
        });
        let limits: Weak<Sender<Relay>> = Arc::downgrade(&inbox);
        // A second relay (a second chat watch) is refused: the first keeps it.
        let _ = memory.relay_app_limit(Box::new(move || {
            if let Some(inbox) = limits.upgrade() {
                let _ = inbox.send(Relay::MemoryLimit);
            }
        }));
        let mode = Arc::clone(mode);
        let memory = Arc::clone(memory);
        supervised::spawn_at(
            THREAD_NAME,
            ThreadQos::Utility,
            Fatal,
            ShutdownBehavior::Continue,
            move || run(&mode, &memory, &relay),
        )?;
        Ok(Self { inbox, _watch: watch })
    }

    /// The watch reached acpmux on `stream`: the current mode goes out on it,
    /// and every later edge, until the next connection replaces it.
    pub(super) fn reached(&self, stream: &UnixStream) {
        if let Ok(writer) = stream.try_clone() {
            let _ = self.inbox.send(Relay::Reached(writer));
        }
    }
}

/// The relay thread: writes the mode and the app's memory limit to the
/// latest connection on each message, until every sender is gone.
fn run(mode: &EnergyMode, memory: &DaemonMemory, relay: &Receiver<Relay>) {
    let mut link: Option<UnixStream> = None;
    let mut sent: u64 = 0;
    while let Ok(message) = relay.recv() {
        let (energy, limit) = match message {
            Relay::Reached(stream) => {
                link = stream.set_write_timeout(Some(WRITE_TIMEOUT)).is_ok().then_some(stream);
                // A new acpmux hears the app's limit only while the app holds one.
                (true, memory.app_limit().is_some())
            }
            Relay::Edge => (true, false),
            Relay::MemoryLimit => (false, true),
        };
        let Some(stream) = link.as_mut() else { continue };
        // The values now, not the change's: two quick changes both send the last.
        let mut written = Ok(());
        if energy {
            sent += 1;
            written = send(stream, "energy", sent, METHOD, json!({"saver": mode.is_saver()}));
        }
        if limit && written.is_ok() {
            sent += 1;
            written = send(stream, "memory", sent, MEMORY_METHOD, limit_params(memory));
        }
        if written.is_err() {
            link = None;
        }
    }
}

/// `_acpmux/memory_limit`'s params: the app's limit, or `level: null` while
/// the app holds none.
fn limit_params(memory: &DaemonMemory) -> Value {
    let Some(limit) = memory.app_limit() else { return json!({"level": null}) };
    json!({
        "level": WireLevel::name(limit.level),
        "mode": limit.mode,
        "override": limit.pressure_override.map(WireLevel::name),
    })
}

/// One request. Its id is a string, so the watch's reader never takes its
/// reply for one of its own numbered calls.
fn send(
    stream: &mut UnixStream,
    tag: &str,
    sent: u64,
    method: &str,
    params: Value,
) -> io::Result<()> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": format!("{tag}-{sent}"),
        "method": method,
        "params": params,
    });
    stream.write_all(format!("{request}\n").as_bytes())?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, ErrorKind};

    use cmux_memory::PressureLevel;

    use crate::memory::{AppLimit, SaverMode};

    use super::*;

    /// The next request acpmux reads, within 5 s.
    fn next(reader: &mut BufReader<UnixStream>) -> Value {
        let mut line = String::new();
        reader.read_line(&mut line).expect("a request");
        serde_json::from_str(&line).expect("JSON")
    }

    fn acpmux_end(stream: UnixStream) -> BufReader<UnixStream> {
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        BufReader::new(stream)
    }

    #[test]
    fn the_mode_goes_out_at_each_connection_and_on_each_edge() {
        let mode = EnergyMode::new(true);
        let memory = Arc::new(DaemonMemory::without_system_source());
        let relay = AcpmuxEnergy::start(&mode, &memory).unwrap();
        let (daemon, acpmux) = UnixStream::pair().unwrap();
        let mut first = acpmux_end(acpmux);
        relay.reached(&daemon);
        let request = next(&mut first);
        assert_eq!(request["method"], METHOD);
        assert_eq!(request["params"], json!({"saver": true}), "the current mode at connect");
        assert!(request["id"].is_string(), "{request}");

        assert!(mode.set_saver(false));
        assert_eq!(next(&mut first)["params"], json!({"saver": false}), "an edge");

        // acpmux restarted: the new connection gets the mode, the old one nothing more.
        let (daemon_again, acpmux_again) = UnixStream::pair().unwrap();
        let mut second = acpmux_end(acpmux_again);
        relay.reached(&daemon_again);
        assert_eq!(next(&mut second)["params"], json!({"saver": false}));
        assert!(mode.set_saver(true));
        assert_eq!(next(&mut second)["params"], json!({"saver": true}));
        first.get_ref().set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let mut line = String::new();
        let stale = first.read_line(&mut line).map_err(|error| error.kind());
        assert!(
            matches!(stale, Err(ErrorKind::WouldBlock | ErrorKind::TimedOut)),
            "{stale:?} {line}"
        );

        // Dropped, the relay hears no more edges.
        drop(relay);
        assert!(mode.set_saver(false));
        second.get_ref().set_read_timeout(Some(Duration::from_millis(100))).unwrap();
        let mut line = String::new();
        assert!(second.read_line(&mut line).map_or(true, |read| read == 0), "{line}");
    }

    /// The app's memory limit goes to acpmux on each change
    /// and to a new acpmux as it connects; `level: null` once the app's
    /// connection ended.
    #[test]
    fn the_apps_memory_limit_goes_out_on_each_change_and_at_connect() {
        const APP: u64 = 3;
        let mode = EnergyMode::new(false);
        let memory = Arc::new(DaemonMemory::without_system_source());
        let relay = AcpmuxEnergy::start(&mode, &memory).unwrap();
        let (daemon, acpmux) = UnixStream::pair().unwrap();
        let mut first = acpmux_end(acpmux);
        relay.reached(&daemon);
        assert_eq!(next(&mut first)["method"], METHOD, "no app limit yet: the mode only");

        let critical = AppLimit {
            level: PressureLevel::Critical,
            mode: SaverMode::Medium,
            pressure_override: Some(PressureLevel::Critical),
        };
        assert!(memory.set_app(APP, critical));
        let pushed = next(&mut first);
        assert_eq!(pushed["method"], MEMORY_METHOD);
        assert_eq!(
            pushed["params"],
            json!({"level": "critical", "mode": "medium", "override": "critical"})
        );
        assert!(pushed["id"].is_string(), "{pushed}");

        // A restarted acpmux hears the mode, then the limit the app holds.
        let (daemon_again, acpmux_again) = UnixStream::pair().unwrap();
        let mut second = acpmux_end(acpmux_again);
        relay.reached(&daemon_again);
        assert_eq!(next(&mut second)["method"], METHOD);
        assert_eq!(next(&mut second)["params"]["level"], "critical");

        // The app's connection ended: its limit went with it.
        assert!(memory.client_left(APP));
        assert_eq!(next(&mut second)["params"], json!({"level": null}));
    }
}
