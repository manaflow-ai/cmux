//! A seed's plan: the prompts the app sends and when, how long each turn streams, which route
//! profile the carrier has, and the faults and when they start.

use std::time::Duration;

use crate::rng::Rng;

/// How long a network drop or a silent relay lasts: under the heartbeat's 15 s deadline, past
/// it, Leo's 5 s and 60 s, and past the daemon's 2 min resume lease, where the session ends and
/// the app must start a new one.
const OUTAGES_S: &[u64] = &[1, 5, 12, 20, 60, 150];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Way {
    Both,
    /// Client to daemon only: the daemon still streams, nothing it is sent arrives.
    Up,
    /// Daemon to client only: the client's frames arrive, nothing comes back.
    Down,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fault {
    /// Every link closes at once and what it held is lost (a relay restart, a TCP reset).
    Cut,
    /// The network drops: links freeze (one way or both) and no new link opens, for `secs`.
    Drop { secs: u64, way: Way },
    /// Every frame is `factor` times slower, for `secs`.
    Slow { factor: u32, secs: u64 },
    /// The relay goes silent; the next dial takes the other relay. The old relay wakes after
    /// `secs` and delivers what it held, late, into links the session has left.
    Swap { secs: u64 },
    /// The machine's session daemon dies mid-stream (no clean close) and is back after `down_ms`.
    /// Its in-memory session is gone; the app must start a new one and resume from its last
    /// event.
    DaemonRestart { down_ms: u64 },
}

impl Fault {
    /// When the fault's cause is over, after it starts.
    pub fn lasts(&self) -> Duration {
        match *self {
            Fault::Cut => Duration::ZERO,
            Fault::Drop { secs, .. } | Fault::Slow { secs, .. } | Fault::Swap { secs } => {
                Duration::from_secs(secs)
            }
            Fault::DaemonRestart { down_ms } => Duration::from_millis(down_ms),
        }
    }

    /// The fault's kind, for the per-kind recovery numbers.
    pub fn kind(&self) -> String {
        match *self {
            Fault::Cut => "cut".into(),
            Fault::Drop { secs, way: Way::Both } => format!("drop {secs}s"),
            Fault::Drop { secs, way } => format!("drop {secs}s {way:?}").to_lowercase(),
            Fault::Slow { .. } => "slow".into(),
            Fault::Swap { .. } => "swap".into(),
            Fault::DaemonRestart { .. } => "daemon restart".into(),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Step {
    pub at: Duration,
    pub fault: Fault,
}

#[derive(Clone, Debug)]
pub struct Prompt {
    pub at: Duration,
    /// Output chunks the turn streams, and the time between two.
    pub chunks: u32,
    pub chunk_every: Duration,
}

#[derive(Clone, Debug)]
pub struct Plan {
    pub prompts: Vec<Prompt>,
    pub faults: Vec<Step>,
    /// One-way latency range of each route, ms: the first relay and the one a swap moves to.
    pub latency_ms: [(u64, u64); 2],
}

impl Plan {
    pub fn new(rng: &mut Rng, faults: bool) -> Self {
        let mut at = Duration::ZERO;
        let prompts = (0..rng.range(2, 6))
            .map(|_| {
                at += Duration::from_millis(rng.range(100, 20_000));
                Prompt {
                    at,
                    chunks: rng.range(3, 60) as u32,
                    chunk_every: Duration::from_millis(rng.range(10, 400)),
                }
            })
            .collect();
        let near = (rng.range(2, 30), rng.range(30, 120));
        let far = (rng.range(5, 60), rng.range(60, 250));
        let mut steps = Vec::new();
        if faults {
            let mut at = Duration::ZERO;
            for _ in 0..rng.range(1, 4) {
                // Faults start while turns stream: the first prompt goes out within 20 s.
                at += Duration::from_millis(rng.range(200, 25_000));
                let outage = OUTAGES_S[rng.range(0, OUTAGES_S.len() as u64 - 1) as usize];
                let fault = match rng.range(0, 9) {
                    0 | 1 => Fault::Cut,
                    2..=4 => Fault::Drop {
                        secs: outage,
                        way: match rng.range(0, 3) {
                            0 => Way::Up,
                            1 => Way::Down,
                            _ => Way::Both,
                        },
                    },
                    5 => Fault::Slow { factor: rng.range(5, 40) as u32, secs: rng.range(1, 30) },
                    6 | 7 => Fault::Swap { secs: outage.min(60) },
                    _ => Fault::DaemonRestart { down_ms: rng.range(50, 8_000) },
                };
                steps.push(Step { at, fault });
                at += fault.lasts();
            }
        }
        Self { prompts, faults: steps, latency_ms: [near, far] }
    }
}
