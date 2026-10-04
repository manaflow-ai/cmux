//! `cloud.machine.*` over `cmux.wire/1` (contract 1.3): list (paged),
//! watch, get, create, rename, start, pause, resize, delete,
//! idle_policy.set, connect_info. Each op sends the checked params to the
//! backend op of the same name.

use crate::api::args;
use crate::api::models::{ConnectInfo, Machine, MachinePage, Revision};
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer};
use serde::Deserialize;
use serde_json::{Map, Value, json};

/// A mutation answer `{machine}`.
#[derive(Deserialize)]
struct MachineAnswer {
    machine: Machine,
}

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.machine.list" => list(ctx, raw),
        "cloud.machine.watch" => {
            // The events are the stream (`cloud.machine.watch` lines after
            // each op result); this read only names where it stands.
            args::object(raw, &[])?;
            Ok(json!({ "revision": ctx.projection.revision() }))
        }
        "cloud.machine.get" => {
            let map = args::object(raw, &["machine"])?;
            let id = args::id(map, "machine")?;
            let answer = ctx.wire(name, args::params(map, &["machine"]));
            let value = gone_if_not_found(ctx, id, answer)?.value;
            let machine: Machine = decode_answer(name, value)?;
            ctx.projection.upsert(machine.clone());
            Ok(json!(machine))
        }
        "cloud.machine.create" => {
            let map = args::object(raw, &["name", "size", "image", "from_snapshot"])?;
            args::name(map, "name")?;
            args::size(map, "size")?;
            args::opt_id(map, "image")?;
            args::opt_id(map, "from_snapshot")?;
            machine_mutation(ctx, name, trimmed(map, &["name", "size", "image", "from_snapshot"]))
        }
        "cloud.machine.rename" => {
            let map = args::object(raw, &["machine", "name"])?;
            args::id(map, "machine")?;
            args::name(map, "name")?.ok_or_else(|| CloudError::invalid("name is required"))?;
            machine_mutation(ctx, name, trimmed(map, &["machine", "name"]))
        }
        "cloud.machine.start" | "cloud.machine.pause" => {
            let map = args::object(raw, &["machine"])?;
            args::id(map, "machine")?;
            machine_mutation(ctx, name, args::params(map, &["machine"]))
        }
        "cloud.machine.resize" => {
            let map = args::object(raw, &["machine", "size"])?;
            args::id(map, "machine")?;
            args::size(map, "size")?;
            machine_mutation(ctx, name, args::params(map, &["machine", "size"]))
        }
        "cloud.machine.idle_policy.set" => {
            let map = args::object(raw, &["machine", "idle_seconds"])?;
            args::id(map, "machine")?;
            args::int(map, "idle_seconds", 0, 604_800, 1)?
                .ok_or_else(|| CloudError::invalid("idle_seconds is required"))?;
            machine_mutation(ctx, name, args::params(map, &["machine", "idle_seconds"]))
        }
        "cloud.machine.delete" => {
            let map = args::object(raw, &["machine"])?;
            let id = args::id(map, "machine")?;
            let answer = ctx.wire(name, args::params(map, &["machine"]));
            let result = gone_if_not_found(ctx, id, answer)?;
            deleted(&result.value)?;
            // The answer's revision is the removal's: an older upsert of
            // this machine never brings it back.
            match result.revision.and_then(|r| Revision::try_from(r).ok()) {
                Some(revision) => ctx.projection.remove_at(id, revision),
                None => ctx.projection.remove(id),
            }
            Ok(json!({ "deleted": true }))
        }
        "cloud.machine.connect_info" => {
            // Exactly one of `machine` and `host` (contract 1.7).
            let map = args::object(raw, &["machine", "host"])?;
            let machine = args::opt_id(map, "machine")?;
            let host = args::opt_id(map, "host")?;
            if machine.is_some() == host.is_some() {
                return Err(CloudError::invalid("give exactly one of machine and host"));
            }
            let answer = ctx.wire(name, args::params(map, &["machine", "host"]));
            let answer = match machine {
                Some(id) => gone_if_not_found(ctx, id, answer)?,
                None => answer?,
            };
            // Serialized without `link_token`: that stays with `cmux link`.
            let info: ConnectInfo = decode_answer(name, answer.value)?;
            Ok(json!(info))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

/// `{deleted: true}`, or a bad answer.
pub(super) fn deleted(value: &Value) -> Result<(), CloudError> {
    if value.get("deleted") == Some(&Value::Bool(true)) {
        Ok(())
    } else {
        Err(CloudError::new(codes::BAD_RESPONSE, "a delete answered without deleted: true"))
    }
}

/// `cloud.machine.not_found` says the machine is gone: it leaves the
/// projection too. The error stays the answer.
fn gone_if_not_found<C: ControlPlane, T>(
    ctx: &mut Ctx<'_, C>,
    id: &str,
    answer: Result<T, CloudError>,
) -> Result<T, CloudError> {
    if let Err(error) = &answer
        && error.upstream_code.as_deref() == Some("cloud.machine.not_found")
    {
        ctx.projection.remove(id);
    }
    answer
}

/// The checked fields, with `name` trimmed as the check read it.
pub(super) fn trimmed(map: &Map<String, Value>, fields: &[&str]) -> Value {
    let mut params = args::params(map, fields);
    if let Some(Value::String(name)) = params.get_mut("name") {
        *name = name.trim().to_owned();
    }
    params
}

/// A mutation that answers `{machine}`: the record goes into the
/// projection (unless the projection already holds a newer one) and the
/// op answers `{machine}`.
pub(super) fn machine_mutation<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    op: &str,
    params: Value,
) -> Result<Value, CloudError> {
    let answer: MachineAnswer = decode_answer(op, ctx.wire(op, params)?.value)?;
    ctx.projection.upsert(answer.machine.clone());
    Ok(json!({ "machine": answer.machine }))
}

/// One `cloud.machine.list` page.
fn list<C: ControlPlane>(ctx: &mut Ctx<'_, C>, raw: &Value) -> Result<Value, CloudError> {
    let map = args::object(raw, &["cursor", "limit"])?;
    let cursor = args::text(map, "cursor", 512)?;
    args::int(map, "limit", 1, 100, 1)?;
    let value = ctx.wire("cloud.machine.list", args::params(map, &["cursor", "limit"]))?.value;
    let page: MachinePage = decode_answer("cloud.machine.list", value)?;
    ctx.projection.apply_page(
        cursor,
        page.machines.clone(),
        page.next_cursor.as_deref(),
        page.revision.clone(),
    );
    Ok(json!({
        "machines": page.machines,
        "next_cursor": page.next_cursor,
        "revision": ctx.projection.revision(),
    }))
}
