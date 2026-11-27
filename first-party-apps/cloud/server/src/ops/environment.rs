//! `cloud.environment.*` over `cmux.wire/1` (plans/cmux-next/cloud-environments-DESIGN.md): list,
//! set (create or edit), build, boot (a new machine) and delete. CloudDO owns the records and checks
//! the inputs as a whole; this server checks the shape and forwards each op to the backend op of the
//! same name. A boot's machine goes into the projection like any create.

use super::machine::{deleted, trimmed};
use crate::api::args;
use crate::api::models::Machine;
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct BootAnswer {
    machine: Machine,
    boot: String,
}

const SET_FIELDS: &[&str] = &["environment", "name", "repo", "setup_script", "env"];

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.environment.list" => {
            args::object(raw, &[])?;
            Ok(ctx.wire(name, json!({}))?.value)
        }
        "cloud.environment.set" => {
            let map = args::object(raw, SET_FIELDS)?;
            args::opt_id(map, "environment")?;
            args::name(map, "name")?;
            if let Some(repo) = map.get("repo")
                && !(repo.is_null() || repo.is_string())
            {
                return Err(CloudError::invalid("repo must be a string or null"));
            }
            if map.get("setup_script").is_some_and(|s| !s.is_string()) {
                return Err(CloudError::invalid("setup_script must be a string"));
            }
            if map.get("env").is_some_and(|e| !e.is_array()) {
                return Err(CloudError::invalid("env must be a list"));
            }
            Ok(ctx.wire(name, trimmed(map, SET_FIELDS))?.value)
        }
        "cloud.environment.build" => {
            let map = args::object(raw, &["environment"])?;
            args::id(map, "environment")?;
            Ok(ctx.wire(name, args::params(map, &["environment"]))?.value)
        }
        "cloud.environment.boot" => {
            let map = args::object(raw, &["environment", "name", "size"])?;
            args::id(map, "environment")?;
            args::name(map, "name")?;
            args::size(map, "size")?;
            let value = ctx.wire(name, trimmed(map, &["environment", "name", "size"]))?.value;
            let answer: BootAnswer = decode_answer(name, value)?;
            ctx.projection.upsert(answer.machine.clone());
            Ok(json!({ "machine": answer.machine, "boot": answer.boot }))
        }
        "cloud.environment.delete" => {
            let map = args::object(raw, &["environment"])?;
            args::id(map, "environment")?;
            deleted(&ctx.wire(name, args::params(map, &["environment"]))?.value)?;
            Ok(json!({ "deleted": true }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}
