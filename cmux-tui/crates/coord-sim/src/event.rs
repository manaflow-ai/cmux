//! One synthetic coordinator's events: the contract between the generator (`generate`), the stand-in agent
//! that streams them into acpmux (`agent`), the load driver (`drive`) and the report (`metrics`).
//!
//! A script is NDJSON, one `SimEvent` per line, in time order. Payload text is filler made from the
//! seed (`filler`), never transcript content; `bytes` is the size the payload must reach on the wire.

// Shared model of the coord-sim subcommands: each of gen, agent, drive, degen, fanin and report reads its own
// part (and the coord-shape.v1 schema fields stay whole), so one subcommand's build leaves the rest unread.
#![allow(dead_code)]

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "t")]
pub enum Op {
    /// An ACP or acpmux event of `kind` ("in:tool_call_update", "mux:turn_started", ...) as the shape names it.
    Event { kind: String },
    /// The person (or another coordinator) sends a prompt: a turn starts.
    UserTurn,
    /// A message to another simulated coordinator, by index (cross-session traffic, `acpmux send`).
    SendTo { to: u32 },
    /// A subagent starts under this chat, streaming `events` events of its own.
    Subagent { events: u32 },
    /// The context is compacted: a compaction boundary and its summary.
    Compaction,
    /// An attachment (an image or a file) of `bytes` bytes goes with the next prompt.
    Attachment,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SimEvent {
    /// Event sequence inside its coordinator, from 1.
    pub seq: u64,
    /// Milliseconds since the coordinator's start, at 1x (the driver divides by its rate multiplier).
    pub at_ms: u64,
    /// Payload size on the wire, bytes.
    pub bytes: u64,
    #[serde(flatten)]
    pub op: Op,
}

/// Deterministic filler of exactly `n` bytes of JSON-safe ASCII (no quote, backslash or control bytes).
pub fn filler(seed: u64, n: usize) -> String {
    const WORDS: [&str; 16] = [
        "alpha ", "build ", "chat ", "delta ", "event ", "frame ", "graph ", "host ", "index ",
        "join ", "kernel ", "lane ", "merge ", "node ", "order ", "patch ",
    ];
    let mut s = String::with_capacity(n + 8);
    let mut x = seed | 1;
    while s.len() < n {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        s.push_str(WORDS[(x & 15) as usize]);
    }
    s.truncate(n);
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filler_is_exact_and_json_safe() {
        for n in [0usize, 1, 7, 1000, 65_537] {
            let f = filler(42, n);
            assert_eq!(f.len(), n);
            assert!(f.bytes().all(|b| (0x20..0x7f).contains(&b) && b != b'"' && b != b'\\'));
        }
    }

    #[test]
    fn event_round_trips() {
        let e = SimEvent { seq: 3, at_ms: 10, bytes: 99, op: Op::SendTo { to: 2 } };
        let line = serde_json::to_string(&e).unwrap();
        assert_eq!(serde_json::from_str::<SimEvent>(&line).unwrap(), e);
    }
}
