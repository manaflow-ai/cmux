//! Classic migration (contract 4): `cloud.migration.status`,
//! `cloud.migration.start` (one way, per user) and `cloud.machine.upgrade`
//! (installs the cmux-next daemon into one classic machine).

use super::machine::machine_mutation;
use crate::api::args;
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Serialize, Deserialize)]
struct Status {
    state: String,
    #[serde(default)]
    classic_count: u32,
    #[serde(default)]
    imported: Vec<String>,
}

#[derive(Serialize, Deserialize)]
struct Started {
    state: String,
}

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.migration.status" => {
            args::object(raw, &[])?;
            let status: Status = decode_answer(name, ctx.wire(name, json!({}))?.value)?;
            Ok(json!(status))
        }
        "cloud.migration.start" => {
            args::object(raw, &[])?;
            let started: Started = decode_answer(name, ctx.wire(name, json!({}))?.value)?;
            Ok(json!(started))
        }
        "cloud.machine.upgrade" => {
            let map = args::object(raw, &["machine"])?;
            args::id(map, "machine")?;
            machine_mutation(ctx, name, args::params(map, &["machine"]))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}
