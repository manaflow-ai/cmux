//! `gauges.carrier` in `daemon status`: where the hub carrier's time goes when this daemon opens
//! a circuit to another of the person's machines, stage by stage, and what a call that rides a
//! kept circuit costs instead (RFD 0056 part 4: "a per-stage reading of set-up time").
//!
//! A new circuit is five stages (`hub_carrier::DialStages`): the platform's Connect ticket, the
//! relay's allocation socket (DNS, TCP, TLS, upgrade, allocate), the far machine joining, Noise
//! XX, and the service hello's answer. Each is its own [`Latencies`] ring, so `p50Ms` of each
//! reads which stage holds a slow dial. `keptStream` is a call that opened a stream on a circuit
//! already open: the cost a second call to the same machine pays, the floor part 4 aims at.
//!
//! `calls` counts, per kind of call, how many rode a kept circuit and how many paid a new one
//! (RFD 0056 part 5, "own ssh": a command on another machine rides the circuit already open, so
//! it costs no new TCP connection and no new transport handshake). `pipe` is a port pipe on the
//! bulk lane (ssh, scp, rsync, a forwarded port: `tools/carrier-pipe` as ssh's ProxyCommand);
//! `cheap` is every other service. The share of pipes that rode a kept circuit is the reading
//! part 5 is held to.
//!
//! Before this the stages were a debug log line only (`RUST_LOG=acpmux::hub_carrier=debug`),
//! which no daemon on a lane runs with, so the 1.2-1.9 s reading in the RFD was taken by hand.

use super::Latencies;
use serde_json::{Value, json};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// The daemon's carrier dial rings: one per process, as a daemon is.
pub fn global() -> &'static CarrierDials {
    static DIALS: OnceLock<CarrierDials> = OnceLock::new();
    DIALS.get_or_init(CarrierDials::default)
}

/// One new circuit's stages, as `hub_carrier::DialStages` measured them.
#[derive(Debug, Clone, Copy, Default)]
pub struct Stages {
    pub ticket: Duration,
    pub relay: Duration,
    pub peer_join: Duration,
    pub noise: Duration,
    /// None for a circuit with no service hello (a plain acpmux link): no answer stage.
    pub answer: Option<Duration>,
}

impl Stages {
    pub fn total(&self) -> Duration {
        self.ticket + self.relay + self.peer_join + self.noise + self.answer.unwrap_or_default()
    }
}

#[derive(Default)]
pub struct CarrierDials {
    ticket: Latencies,
    relay: Latencies,
    peer_join: Latencies,
    noise: Latencies,
    answer: Latencies,
    circuit: Latencies,
    kept_stream: Latencies,
    pipe: CallCounts,
    cheap: CallCounts,
    /// The newest circuit's stages, whole: a bench reads one dial's split (the rings above
    /// mix every dial the process made).
    last: std::sync::Mutex<Option<Stages>>,
}

/// How many calls of one kind rode a kept circuit and how many opened a new one.
#[derive(Default)]
struct CallCounts {
    kept: AtomicU64,
    new_circuit: AtomicU64,
}

impl CallCounts {
    fn status(&self) -> Value {
        json!({
            "kept": self.kept.load(Ordering::Relaxed),
            "newCircuit": self.new_circuit.load(Ordering::Relaxed),
        })
    }
}

impl CarrierDials {
    /// A new circuit opened, its stages `stages`.
    pub fn circuit(&self, stages: &Stages) {
        self.ticket.record(stages.ticket);
        self.relay.record(stages.relay);
        self.peer_join.record(stages.peer_join);
        self.noise.record(stages.noise);
        if let Some(answer) = stages.answer {
            self.answer.record(answer);
        }
        self.circuit.record(stages.total());
        *self.last.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(*stages);
    }

    /// The newest circuit's stages; None before the first.
    pub fn last(&self) -> Option<Stages> {
        *self.last.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// A call opened a stream on a kept circuit that was already open, in `took`.
    pub fn kept_stream(&self, took: Duration) {
        self.kept_stream.record(took);
    }

    /// A call got its stream: `pipe` (a port pipe on the bulk lane: ssh, scp, a forwarded port)
    /// or not, on a circuit already open (`kept`) or on one it opened.
    pub fn call(&self, pipe: bool, kept: bool) {
        let counts = if pipe { &self.pipe } else { &self.cheap };
        let n = if kept { &counts.kept } else { &counts.new_circuit };
        n.fetch_add(1, Ordering::Relaxed);
    }

    /// `{newCircuit: {total, ticket, relay, peerJoin, noise, answer}, keptStream}`, each a
    /// [`Latencies`] reading.
    pub fn status(&self) -> Value {
        json!({
            "newCircuit": {
                "total": self.circuit.status(),
                "ticket": self.ticket.status(),
                "relay": self.relay.status(),
                "peerJoin": self.peer_join.status(),
                "noise": self.noise.status(),
                "answer": self.answer.status(),
            },
            "keptStream": self.kept_stream.status(),
            "calls": { "pipe": self.pipe.status(), "cheap": self.cheap.status() },
        })
    }
}

/// The `carrier:` line of `acpmux status`, from `gauges.carrier`: the new-circuit p50 with each
/// stage's p50, and the kept-stream p50. None before this daemon dialed anything.
pub fn status_line(carrier: &Value) -> Option<String> {
    let p50 = |v: &Value| v["p50Ms"].as_f64().map(|ms| format!("{ms:.0} ms"));
    let count = |v: &Value| v["count"].as_u64().unwrap_or(0);
    let new = &carrier["newCircuit"];
    let kept = &carrier["keptStream"];
    let mut parts = Vec::new();
    if count(&new["total"]) > 0 {
        let stages = [
            ("ticket", "ticket"),
            ("relay", "relay"),
            ("join", "peerJoin"),
            ("noise", "noise"),
            ("answer", "answer"),
        ]
        .iter()
        .filter_map(|(label, key)| {
            (count(&new[key]) > 0).then(|| p50(&new[key]).map(|ms| format!("{label} {ms}")))?
        })
        .collect::<Vec<_>>()
        .join(", ");
        parts.push(format!(
            "new circuit p50 {} over {} ({stages})",
            p50(&new["total"])?,
            count(&new["total"])
        ));
    }
    if count(kept) > 0 {
        parts.push(format!("call on a kept circuit p50 {} over {}", p50(kept)?, count(kept)));
    }
    let pipe = &carrier["calls"]["pipe"];
    let (kept, new) =
        (pipe["kept"].as_u64().unwrap_or(0), pipe["newCircuit"].as_u64().unwrap_or(0));
    if kept + new > 0 {
        parts.push(format!("ssh and pipes {kept} of {} on a kept circuit", kept + new));
    }
    (!parts.is_empty()).then(|| parts.join("; "))
}

#[cfg(test)]
#[path = "carrier_tests.rs"]
mod tests;
