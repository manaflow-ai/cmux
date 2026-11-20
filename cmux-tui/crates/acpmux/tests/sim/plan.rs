//! What one seed does: the app's sends and the faults, each at a simulated time. The plan is
//! drawn before anything runs, so a run without faults (`Faults::none`) sends exactly what the
//! faulty run sends: the uninterrupted run the invariants compare a resumed one with.

use crate::rng::Rng;
use std::time::Duration;

#[derive(Clone, Debug)]
pub struct Prompt {
    /// After the app's chat exists.
    pub at: Duration,
    pub prompt_id: String,
    pub text: String,
    /// Sent as a steer into a running turn (`_meta.acpmux.steer`).
    pub steer: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fault {
    /// The daemon process dies at this step and starts again after `down`.
    Crash { down: Duration },
    /// The daemon's machine loses power: a crash that also drops what was not flushed.
    PowerLoss { down: Duration },
    /// Nothing the daemon sends reaches the app for `lasting`, while the app's sends still
    /// reach the daemon: the node looks online but nothing comes back (sr2-gateway).
    OneWay { lasting: Duration },
    /// Both directions are cut for `lasting`.
    Partition { lasting: Duration },
    /// Messages between them wait up to `lasting` (held, then released together).
    Hold { lasting: Duration },
}

#[derive(Clone, Debug)]
pub struct Plan {
    pub sends: Vec<Prompt>,
    /// After the app's chat exists, sorted by time.
    pub faults: Vec<(Duration, Fault)>,
}

/// Which kinds of fault a run draws from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Kinds {
    pub crash: bool,
    pub power_loss: bool,
    pub network: bool,
}

impl Plan {
    pub fn draw(rng: &mut Rng, kinds: Kinds) -> Self {
        let n = rng.range(2, 6);
        let mut at = Duration::ZERO;
        let mut sends = Vec::new();
        for i in 0..n {
            at += Duration::from_millis(rng.range(0, 8_000));
            sends.push(Prompt {
                at,
                prompt_id: format!("p{i}"),
                text: format!("task {i}"),
                steer: i > 0 && rng.chance(35),
            });
        }
        let span = at + Duration::from_secs(20);
        let mut faults = Vec::new();
        for _ in 0..rng.range(0, 4) {
            let when = Duration::from_millis(rng.range(0, span.as_millis() as u64));
            let ms = |rng: &mut Rng, lo, hi| Duration::from_millis(rng.range(lo, hi));
            let mut choices = Vec::new();
            if kinds.crash {
                choices.push(Fault::Crash { down: ms(rng, 0, 3_000) });
            }
            if kinds.power_loss {
                choices.push(Fault::PowerLoss { down: ms(rng, 0, 3_000) });
            }
            if kinds.network {
                choices.push(Fault::OneWay { lasting: ms(rng, 500, 60_000) });
                choices.push(Fault::Partition { lasting: ms(rng, 500, 30_000) });
                choices.push(Fault::Hold { lasting: ms(rng, 100, 10_000) });
            }
            if choices.is_empty() {
                break;
            }
            let pick = rng.range(0, choices.len() as u64 - 1) as usize;
            faults.push((when, choices[pick]));
        }
        faults.sort_by_key(|(t, _)| *t);
        Plan { sends, faults }
    }
}
