//! Growing a chat's machine disk before a move, the app's `CloudStartChat+GrowDisk`
//! rules moved here (cmuxterm-hq `docs/rfd/drafts/why-swift.md`): the sizes asked
//! for and what each resize answer means. The app measures the chat and makes
//! the resize calls.

use serde::{Deserialize, Serialize};

const MIB: u64 = 1_048_576;
/// Disks grow in steps of this many bytes (4 GiB).
pub const STEP_BYTES: u64 = 4 * 1024 * MIB;

/// The disk in MB for `bytes` rounded up to a step, at most `cap` bytes.
pub fn disk_mb(bytes: i64, cap: u64) -> u64 {
    let bytes = bytes.max(0) as u64;
    (bytes.div_ceil(STEP_BYTES) * STEP_BYTES).min(cap) / MIB
}

/// The chat's sizes, as the app measured them (bytes).
#[derive(Clone, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Sizes {
    /// The chat's bytes and the room it needs at least; either unknown means no grow.
    #[serde(default)]
    pub floor: Option<i64>,
    #[serde(default)]
    pub needed: Option<i64>,
    /// The largest disk any plan has.
    pub max_disk: u64,
}

/// What the last resize answered.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
#[serde(tag = "answer", rename_all = "snake_case")]
pub enum Answer {
    Done,
    /// The plan caps the disk: `plan_max` names the plan size, `largest` its disk (bytes).
    Locked {
        #[serde(default)]
        plan_max: Option<String>,
        #[serde(default)]
        largest: Option<u64>,
    },
    Failed,
}

/// What the app does next.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "do", rename_all = "snake_case")]
pub enum Next {
    /// Resize the disk to `disk_mb`.
    Resize {
        #[serde(rename = "diskMb")]
        disk_mb: u64,
    },
    Grown,
    NotGrown,
    /// The chat needs more than `size` holds.
    PastPlan {
        size: String,
    },
}

/// The largest plan size, as the platform spells it (`2xl`).
pub const LARGEST_SIZE: &str = "2xl";

/// The first step.
pub fn start(sizes: &Sizes) -> Next {
    let (Some(floor), Some(needed)) = (sizes.floor, sizes.needed) else {
        return Next::NotGrown;
    };
    if floor > 0 && floor as u64 > sizes.max_disk {
        return Next::PastPlan { size: LARGEST_SIZE.to_owned() };
    }
    Next::Resize { disk_mb: disk_mb(needed, sizes.max_disk) }
}

/// The step after a resize answer; `retried` when this answer is to the plan-capped retry.
pub fn after(sizes: &Sizes, answer: &Answer, retried: bool) -> Next {
    match answer {
        Answer::Done => Next::Grown,
        Answer::Failed => Next::NotGrown,
        Answer::Locked { plan_max, largest } => match (plan_max, retried) {
            (Some(plan), true) => Next::PastPlan { size: plan.clone() },
            (Some(plan), false) => {
                let (Some(floor), Some(needed), Some(largest)) =
                    (sizes.floor, sizes.needed, *largest)
                else {
                    return Next::NotGrown;
                };
                if floor > 0 && floor as u64 > largest {
                    Next::PastPlan { size: plan.clone() }
                } else {
                    Next::Resize { disk_mb: disk_mb(needed, largest) }
                }
            }
            (None, _) => Next::NotGrown,
        },
    }
}

#[cfg(test)]
mod tests;
