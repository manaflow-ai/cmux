//! Team wire events into the projection (contract 1.4). The host reads the
//! team wire (`/v1/wire/team`) and sends each Cloud event to the serve loop
//! as `{"type":"team.event","event","data"}`; the loop applies it here and
//! then sends the `cloud.machine.watch` events it caused. Every provider
//! state change is an event, so nothing polls.
//!
//! - `cloud.machine.upsert {machine}`: written unless the projection holds a
//!   newer revision of it (or a newer removal).
//! - `cloud.machine.removed {machine, revision}`: removed unless the
//!   projection holds a newer record.
//! - `cloud.machine.state {v, t, machine, revision, state?}`: one frame of a
//!   machine's pushed state (cmux-platform `MachineState`, the socket
//!   `GET /v1/cloud/machines/{machine}/state` the app holds for each machine
//!   it shows). `t: state` carries `state.record`, the machine's public
//!   record, written as an upsert is (by its backend revision); `t: removed`
//!   removes the machine. Either marks the machine pushed, so a parked op
//!   on it waits for the push instead of reading every second
//!   (`crate::link::park`).
//! - `cloud.snapshot.*` and `cloud.plan.changed` change no machine; pages
//!   read them again on their own events.

use super::error::{CloudError, codes};
use super::models::{Machine, Revision};
use crate::ops::Projection;
use serde::Deserialize;
use serde_json::Value;

#[derive(Deserialize)]
struct Upsert {
    machine: Machine,
}

/// A `cloud.machine.state` frame: `state` (with the record) or `removed`.
#[derive(Deserialize)]
struct StateFrame {
    t: String,
    machine: String,
    #[serde(default)]
    state: Option<PushedState>,
}

#[derive(Deserialize)]
struct PushedState {
    record: Machine,
}

#[derive(Deserialize)]
struct Removed {
    machine: String,
    revision: Revision,
}

fn decode<T: serde::de::DeserializeOwned>(event: &str, data: &Value) -> Result<T, CloudError> {
    serde_json::from_value(data.clone())
        .map_err(|e| CloudError::new(codes::BAD_RESPONSE, format!("{event}: {e}")))
}

/// Applies one event. An event of another family is refused; a Cloud
/// event that changes no machine is accepted and does nothing.
pub(crate) fn apply(
    projection: &mut Projection,
    event: &str,
    data: &Value,
) -> Result<(), CloudError> {
    match event {
        "cloud.machine.upsert" => {
            let Upsert { machine } = decode(event, data)?;
            projection.upsert(machine);
        }
        "cloud.machine.removed" => {
            let Removed { machine, revision } = decode(event, data)?;
            projection.remove_at(&machine, revision);
        }
        "cloud.machine.state" => {
            let frame: StateFrame = decode(event, data)?;
            match (frame.t.as_str(), frame.state) {
                ("state", Some(PushedState { record })) if record.id == frame.machine => {
                    projection.mark_pushed(&frame.machine);
                    projection.upsert(record);
                }
                // The socket's first frame before anything was put: the
                // push is live, the record comes with the next change.
                ("state", None) => projection.mark_pushed(&frame.machine),
                ("removed", _) => {
                    projection.mark_pushed(&frame.machine);
                    projection.remove(&frame.machine);
                }
                _ => return Err(CloudError::invalid(format!("{event}: not a machine state frame"))),
            }
        }
        "cloud.snapshot.upsert" | "cloud.snapshot.removed" | "cloud.plan.changed" => {}
        other => {
            return Err(CloudError::invalid(format!("{other} is not a Cloud team event")));
        }
    }
    Ok(())
}
