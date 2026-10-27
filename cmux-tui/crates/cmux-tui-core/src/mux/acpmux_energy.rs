//! Energy Saver reaches this machine's acpmux (p14-energy-034). The daemon's
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
//! The mode's watcher only queues an edge for the `mux-acpmux-energy` thread,
//! which does the write, so `energy.set` stays a flip and a notify. The thread
//! waits on its channel with no timeout: no wake while nothing changes. Its
//! replies come back on the watch's connection, which reads past them.

use std::io::{self, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Duration;

use cmux_threads::ThreadQos;
use serde_json::json;

use crate::wake::{EnergyMode, EnergyWatch};

/// acpmux's Energy Saver method (`acpmux/src/rpc.rs`, `MUX_ENERGY`).
pub(super) const METHOD: &str = "_acpmux/energy";
const THREAD_NAME: &str = "mux-acpmux-energy";
/// A write acpmux does not take within this long ends the relay's link.
const WRITE_TIMEOUT: Duration = Duration::from_secs(3);

enum Relay {
    /// The watch reached acpmux: this is a writer on its connection.
    Reached(UnixStream),
    /// The mode changed.
    Edge,
}

/// The relay thread's inbox and the mode watch that feeds it. Dropping it
/// ends the thread.
pub(super) struct AcpmuxEnergy {
    inbox: Sender<Relay>,
    _watch: EnergyWatch,
}

impl AcpmuxEnergy {
    /// Starts the relay thread for `mode`.
    pub(super) fn start(mode: &Arc<EnergyMode>) -> io::Result<Self> {
        let (inbox, relay) = mpsc::channel();
        let edges = inbox.clone();
        let watch = mode.watch(move || {
            let _ = edges.send(Relay::Edge);
        });
        let mode = Arc::clone(mode);
        cmux_threads::spawn(THREAD_NAME, ThreadQos::Utility, move || run(&mode, &relay))?;
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

/// The relay thread: writes the mode to the latest connection on each
/// message, until every sender is gone.
fn run(mode: &EnergyMode, relay: &Receiver<Relay>) {
    let mut link: Option<UnixStream> = None;
    let mut sent: u64 = 0;
    while let Ok(message) = relay.recv() {
        if let Relay::Reached(stream) = message {
            link = stream.set_write_timeout(Some(WRITE_TIMEOUT)).is_ok().then_some(stream);
        }
        let Some(stream) = link.as_mut() else { continue };
        sent += 1;
        // The mode now, not the edge's: two quick edges both send the last value.
        if send(stream, mode.is_saver(), sent).is_err() {
            link = None;
        }
    }
}

/// One `_acpmux/energy` request. Its id is a string, so the watch's reader
/// never takes its reply for one of its own numbered calls.
fn send(stream: &mut UnixStream, saver: bool, sent: u64) -> io::Result<()> {
    let request = json!({
        "jsonrpc": "2.0",
        "id": format!("energy-{sent}"),
        "method": METHOD,
        "params": {"saver": saver},
    });
    stream.write_all(format!("{request}\n").as_bytes())?;
    stream.flush()
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead, BufReader, ErrorKind};

    use serde_json::Value;

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
        let relay = AcpmuxEnergy::start(&mode).unwrap();
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
}
