//! A stand-in burst script for `drive` when no `--scripts DIR` is given (until `coord-sim gen`
//! lands its scripts): one coordinator's `SimEvent` NDJSON at the shape's 1x peaks.
//!
//! Per coordinator, over `seconds` at 1x: a steady stream at the all-sessions p99 rate
//! (`global_events_per_s.p99`, 112 ev/s on the default shape), one one-second burst of the
//! single-session peak (`per_session.peak_events_1s.max`, 5,592 events) at a staggered second,
//! a user turn every 10 s, a send to the next coordinator every 5 s, a 50-event subagent each
//! turn and one compaction. Kinds and sizes are drawn from the shape's `in:` kinds (what an agent
//! sends); sizes are capped at 256 KiB.

use crate::event::{Op, SimEvent};
use crate::rng::Rng;
use crate::shape::Shape;

const SIZE_CAP: u64 = 256 * 1024;

pub fn script(
    shape: &Shape,
    coord: u32,
    coordinators: u32,
    seconds: u64,
    seed: u64,
) -> Vec<SimEvent> {
    let mut rng = Rng::new(seed).fork(coord as u64 + 1);
    let kinds: Vec<(String, u64)> =
        shape.kind_mix().into_iter().filter(|(k, _)| k.starts_with("in:")).collect();
    let weights: Vec<u64> = kinds.iter().map(|(_, n)| *n).collect();
    let base_rate = shape.acpmux.global_events_per_s.p99.max(1);
    let burst = shape.acpmux.per_session.peak_events_1s.max.max(1);
    let burst_at = if seconds > 2 { 1 + (coord as u64 * 7) % (seconds - 1) } else { 0 };
    let mut times: Vec<(u64, Op)> = Vec::new();
    for s in 0..seconds {
        let n = base_rate + if s == burst_at { burst } else { 0 };
        for _ in 0..n {
            let at = s * 1000 + rng.below(1000);
            let i = rng.weighted(&weights);
            let kind = kinds
                .get(i)
                .map(|(k, _)| k.clone())
                .unwrap_or_else(|| "in:agent_message_chunk".into());
            times.push((at, Op::Event { kind }));
        }
        if s % 10 == 0 && s > 0 {
            times.push((s * 1000, Op::UserTurn));
            times.push((s * 1000 + 200, Op::Subagent { events: 50 }));
        }
        if s % 5 == 2 {
            times.push((
                s * 1000 + rng.below(1000),
                Op::SendTo { to: (coord + 1) % coordinators.max(1) },
            ));
        }
        if s == seconds / 2 {
            times.push((s * 1000 + 500, Op::Compaction));
        }
    }
    times.sort_by_key(|(at, _)| *at);
    times
        .into_iter()
        .enumerate()
        .map(|(i, (at_ms, op))| {
            let bytes = match &op {
                Op::Event { kind } => shape
                    .acpmux
                    .kind_bytes
                    .get(kind)
                    .map(|h| h.sample(&mut rng))
                    .unwrap_or(400)
                    .clamp(200, SIZE_CAP),
                Op::Subagent { events } => *events as u64 * 400,
                _ => 600,
            };
            SimEvent { seq: i as u64 + 1, at_ms, bytes, op }
        })
        .collect()
}

#[cfg(test)]
#[path = "synth_tests.rs"]
mod tests;
