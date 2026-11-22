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
        "cloud.snapshot.upsert" | "cloud.snapshot.removed" | "cloud.plan.changed" => {}
        other => {
            return Err(CloudError::invalid(format!("{other} is not a Cloud team event")));
        }
    }
    Ok(())
}
