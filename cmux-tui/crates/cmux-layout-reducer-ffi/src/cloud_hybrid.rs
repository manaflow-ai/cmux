//! `cmux-cloud-start-core`'s hybrid start over the JSON channel (`cloud_hybrid_*`): the app holds
//! the start's state between calls, sends it with each event and its monotonic clock, and runs the
//! effects the answer lists (start here, make the machine, move, deliver or hold a prompt, show).

use cmux_cloud_start_core::hybrid::{self, Account, Event, State};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_hybrid_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Step {
    #[serde(default)]
    state: Option<State>,
    event: Event,
    now: u64,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // Whether a Cloud start of this account is hybrid, and why not.
        b"cloud_hybrid_enabled" => {
            let account: Account = read(request)?;
            match hybrid::enabled(&account) {
                Ok(()) => json!({ "enabled": true }),
                Err(off) => json!({ "enabled": false, "off": off }),
            }
        }
        // One event: the next state and the effects to run, in order.
        b"cloud_hybrid_step" => {
            let step: Step = read(request)?;
            serde_json::to_value(hybrid::step(step.state.unwrap_or_default(), step.event, step.now))
                .map_err(|_| ERR_INVALID)?
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
