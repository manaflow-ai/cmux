//! `cloud.machine.*`: list, get, create, rename, start, pause, resize,
//! delete, stats, idle_policy.set over `/api/vm`.

use crate::api::args;
use crate::api::models::{Machine, MachineList, Stats};
use crate::api::{CloudError, ControlPlane, Ctx, codes};
use serde_json::{Value, json};

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.machine.list" => list(ctx, raw),
        "cloud.machine.get" => {
            let id = args::id(args::object(raw, &["machine"])?, "machine")?;
            let answer = ctx.call("GET", format!("/api/vm/{id}"), None)?;
            merged(ctx, &answer)
        }
        "cloud.machine.create" => create(ctx, raw),
        "cloud.machine.rename" => rename(ctx, raw),
        "cloud.machine.start" => lifecycle(ctx, raw, "resume"),
        "cloud.machine.pause" => lifecycle(ctx, raw, "pause"),
        "cloud.machine.resize" => resize(ctx, raw),
        "cloud.machine.delete" => {
            let id = args::id(args::object(raw, &["machine"])?, "machine")?;
            ctx.call("DELETE", format!("/api/vm/{id}"), None)?;
            ctx.projection.remove(id);
            Ok(json!({ "ok": true }))
        }
        "cloud.machine.stats" => {
            let id = args::id(args::object(raw, &["machine"])?, "machine")?;
            let path = format!("/api/vm/{id}/stats");
            let stats: Stats =
                crate::api::decode_answer(&path, ctx.call("GET", path.clone(), None)?)?;
            Ok(json!(stats))
        }
        "cloud.machine.idle_policy.set" => {
            let map = args::object(raw, &["machine", "idleTimeoutSeconds"])?;
            args::id(map, "machine")?;
            args::int(map, "idleTimeoutSeconds", 0, 604_800, 1)?
                .ok_or_else(|| CloudError::invalid("idleTimeoutSeconds is required"))?;
            Err(CloudError::new(
                codes::UNSUPPORTED,
                "The cmux Cloud API has no idle policy route yet",
            ))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

/// `GET /api/vm`: refreshes the whole projection.
pub(super) fn fetch_list<C: ControlPlane>(ctx: &mut Ctx<'_, C>) -> Result<MachineList, CloudError> {
    let list: MachineList =
        crate::api::decode_answer("/api/vm", ctx.call("GET", "/api/vm".into(), None)?)?;
    ctx.projection.replace_all(list.vms.clone());
    Ok(list)
}

fn list<C: ControlPlane>(ctx: &mut Ctx<'_, C>, raw: &Value) -> Result<Value, CloudError> {
    args::object(raw, &[])?;
    fetch_list(ctx)?;
    let machines: Vec<&Machine> = ctx.projection.machines().collect();
    Ok(json!({ "machines": machines, "revision": ctx.projection.revision() }))
}

/// Merges a machine answer into the projection and returns the record.
pub(super) fn merged<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    answer: &Value,
) -> Result<Value, CloudError> {
    let machine = ctx
        .projection
        .merge(answer)
        .ok_or_else(|| CloudError::new(codes::BAD_RESPONSE, "the answer is not a machine"))?;
    Ok(json!(machine))
}

fn create<C: ControlPlane>(ctx: &mut Ctx<'_, C>, raw: &Value) -> Result<Value, CloudError> {
    let map = args::object(raw, &["displayName", "memoryMb", "kind"])?;
    let mut body = serde_json::Map::new();
    if let Some(name) = args::text(map, "displayName", 128)? {
        body.insert("displayName".into(), json!(name));
    }
    if let Some(mb) = args::int(map, "memoryMb", 1024, 65_536, 1)? {
        body.insert("memoryMb".into(), json!(mb));
    }
    if let Some(kind) = args::text(map, "kind", 32)? {
        body.insert("kind".into(), json!(kind));
    }
    let answer = ctx.call("POST", "/api/vm".into(), Some(Value::Object(body)))?;
    merged(ctx, &answer)
}

fn rename<C: ControlPlane>(ctx: &mut Ctx<'_, C>, raw: &Value) -> Result<Value, CloudError> {
    let map = args::object(raw, &["machine", "displayName"])?;
    let id = args::id(map, "machine")?;
    let name = match map.get("displayName") {
        Some(Value::Null) => None,
        Some(Value::String(s)) if s.chars().count() <= 128 => {
            Some(s.trim()).filter(|s| !s.is_empty())
        }
        _ => {
            return Err(CloudError::invalid(
                "displayName must be text of at most 128 characters or null",
            ));
        }
    };
    let answer =
        ctx.call("PATCH", format!("/api/vm/{id}"), Some(json!({ "displayName": name })))?;
    merged(ctx, &answer)
}

fn lifecycle<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    raw: &Value,
    verb: &str,
) -> Result<Value, CloudError> {
    let id = args::id(args::object(raw, &["machine"])?, "machine")?;
    let answer = ctx.call("POST", format!("/api/vm/{id}/{verb}"), None)?;
    merged(ctx, &answer)
}

fn resize<C: ControlPlane>(ctx: &mut Ctx<'_, C>, raw: &Value) -> Result<Value, CloudError> {
    let map = args::object(raw, &["machine", "cpu", "memoryMb", "storageMb"])?;
    let id = args::id(map, "machine")?;
    let mut body = serde_json::Map::new();
    for (field, min, max, step) in
        [("cpu", 1, 32, 1), ("memoryMb", 4096, 65_536, 1024), ("storageMb", 4096, 262_144, 4096)]
    {
        if let Some(n) = args::int(map, field, min, max, step)? {
            body.insert(field.into(), json!(n));
        }
    }
    if body.is_empty() {
        return Err(CloudError::invalid("give cpu, memoryMb or storageMb"));
    }
    let path = format!("/api/vm/{id}/resize");
    let stats: Stats = crate::api::decode_answer(
        &path,
        ctx.call("POST", path.clone(), Some(Value::Object(body)))?,
    )?;
    Ok(json!(stats))
}
