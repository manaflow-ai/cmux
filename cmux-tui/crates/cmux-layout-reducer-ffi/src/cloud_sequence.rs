//! `cmux-cloud-start-core`'s start sequencer over the JSON channel (`cloud_sequence_*`): the app
//! holds the state between calls, sends it with each event and its monotonic clock, and runs the
//! effects the answer lists (a step, a log line, a cancel, the end).

use cmux_cloud_start_core::sequence::{self, Event, State};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_sequence_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Step {
    #[serde(default)]
    state: State,
    event: Event,
    now: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Recheck {
    from_cache: bool,
    since_guest_check_ms: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Approvals {
    #[serde(default)]
    daemon_said_safe: bool,
    #[serde(default)]
    holds_key: bool,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // One event: the next state and the effects to run, in order.
        b"cloud_sequence_step" => {
            let step: Step = read(request)?;
            serde_json::to_value(sequence::step(step.state, step.event, step.now))
                .map_err(|_| ERR_INVALID)?
        }
        // Whether the credential transfer checks the guest again before it writes.
        b"cloud_sequence_recheck_guest" => {
            let recheck: Recheck = read(request)?;
            json!({ "recheck": sequence::recheck_guest(recheck.from_cache, recheck.since_guest_check_ms) })
        }
        // How a start turns remote approvals on: held, restart-now or if-idle.
        b"cloud_sequence_approvals" => {
            let facts: Approvals = read(request)?;
            json!({ "approvals": sequence::approvals(facts.daemon_said_safe, facts.holds_key) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
