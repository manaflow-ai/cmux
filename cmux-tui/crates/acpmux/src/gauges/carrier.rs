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
//! Before this the stages were a debug log line only (`RUST_LOG=acpmux::hub_carrier=debug`),
//! which no daemon on a lane runs with, so the 1.2-1.9 s reading in the RFD was taken by hand.

use super::Latencies;
use serde_json::{Value, json};
use std::sync::OnceLock;
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
    }

    /// A call opened a stream on a kept circuit that was already open, in `took`.
    pub fn kept_stream(&self, took: Duration) {
        self.kept_stream.record(took);
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
    (!parts.is_empty()).then(|| parts.join("; "))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(n: u64) -> Duration {
        Duration::from_millis(n)
    }

    #[test]
    fn a_circuit_records_each_stage_and_its_total() {
        let dials = CarrierDials::default();
        dials.circuit(&Stages {
            ticket: ms(10),
            relay: ms(200),
            peer_join: ms(300),
            noise: ms(150),
            answer: Some(ms(40)),
        });
        let status = dials.status();
        let new = &status["newCircuit"];
        assert_eq!(new["total"]["p50Ms"], 700.0, "{status}");
        assert_eq!(new["relay"]["p50Ms"], 200.0, "{status}");
        assert_eq!(new["peerJoin"]["p50Ms"], 300.0, "{status}");
        assert_eq!(new["answer"]["count"], 1, "{status}");
        assert_eq!(status["keptStream"]["count"], 0, "{status}");
    }

    #[test]
    fn a_plain_acpmux_circuit_has_no_answer_sample() {
        let dials = CarrierDials::default();
        dials.circuit(&Stages { noise: ms(5), ..Stages::default() });
        let status = dials.status();
        assert_eq!(status["newCircuit"]["answer"]["count"], 0, "{status}");
        assert_eq!(status["newCircuit"]["total"]["count"], 1, "{status}");
    }

    #[test]
    fn the_status_line_names_each_stage_and_the_kept_call() {
        let dials = CarrierDials::default();
        assert_eq!(status_line(&dials.status()), None);
        dials.circuit(&Stages {
            ticket: ms(10),
            relay: ms(200),
            peer_join: ms(300),
            noise: ms(150),
            answer: None,
        });
        dials.kept_stream(ms(70));
        assert_eq!(
            status_line(&dials.status()).unwrap(),
            "new circuit p50 660 ms over 1 (ticket 10 ms, relay 200 ms, join 300 ms, \
             noise 150 ms); call on a kept circuit p50 70 ms over 1"
        );
    }
}
