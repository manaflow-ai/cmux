//! `cmux-cloud-tasks` over the JSON channel (`cloud_task_*`): the follower of the cloud tasks the
//! app handed off (sandboxed Runs, hand-offs). The app holds the state between calls, sends it with
//! each event and runs the effects the answer lists (its polls, waiters, saved list and banners).

use cmux_cloud_tasks::follower::{self, Event, Kind};
use cmux_cloud_tasks::{handoff, model};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_task_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Step {
    #[serde(default)]
    source: Kind,
    now: f64,
    #[serde(default)]
    state: model::State,
    event: Event,
}

#[derive(Deserialize)]
struct Load {
    #[serde(default)]
    saved: Option<String>,
}

#[derive(Deserialize)]
struct Saved {
    state: model::State,
}

#[derive(Deserialize)]
struct Status {
    status: String,
    #[serde(default)]
    turn: Option<i64>,
    #[serde(default)]
    state: Option<String>,
}

#[derive(Deserialize)]
struct Time {
    time: serde_json::Value,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // One event: the next state and the effects to run, in order.
        b"cloud_task_step" => {
            let step: Step = read(request)?;
            serde_json::to_value(follower::step(step.source, step.state, step.event, step.now))
                .map_err(|_| ERR_INVALID)?
        }
        // A launch's state from the saved list (none, or one that does not read: empty).
        b"cloud_task_load" => {
            let load: Load = read(request)?;
            json!({ "state": model::load(load.saved.as_deref()) })
        }
        // The saved list of a state, in the app's long-standing format.
        b"cloud_task_saved" => {
            let saved: Saved = read(request)?;
            json!({ "saved": model::saved(&saved.state) })
        }
        // A listed hand-off's status: whether it can still change, whether its turn runs, and
        // what of it is told.
        b"cloud_task_handoff" => {
            let status: Status = read(request)?;
            json!({
                "open": handoff::is_open(&status.status, status.state.as_deref()),
                "running": handoff::is_running(&status.status),
                "notice": handoff::notice(&status.status, status.turn),
            })
        }
        b"cloud_task_handoff_statuses" => json!({
            "statuses": handoff::STATUSES,
            "turnEnds": handoff::TURN_ENDS,
            "turnRuns": handoff::TURN_RUNS,
        }),
        // A store time (a number of milliseconds, or ISO 8601) as milliseconds since 1970; null
        // when it is neither.
        b"cloud_task_millis" => {
            let time: Time = read(request)?;
            json!({ "millis": handoff::millis(&time.time) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
