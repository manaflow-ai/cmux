//! `cloud.snapshot.*`: list, create, restore (a new machine), fork (a new
//! machine), delete.

use super::machine::merged;
use crate::api::args;
use crate::api::models::Snapshot;
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct SnapshotList {
    snapshots: Vec<Snapshot>,
}

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.snapshot.list" => {
            let id = args::id(args::object(raw, &["machine"])?, "machine")?;
            let path = format!("/api/vm/{id}/snapshots");
            let list: SnapshotList = decode_answer(&path, ctx.call("GET", path.clone(), None)?)?;
            Ok(json!({ "snapshots": list.snapshots }))
        }
        "cloud.snapshot.create" => {
            let map = args::object(raw, &["machine", "name"])?;
            let id = args::id(map, "machine")?;
            let body = named_body(map)?;
            let path = format!("/api/vm/{id}/snapshot");
            let snapshot: Snapshot =
                decode_answer(&path, ctx.call("POST", path.clone(), Some(body))?)?;
            Ok(json!(snapshot))
        }
        "cloud.snapshot.restore" => {
            let snapshot = args::id(args::object(raw, &["snapshot"])?, "snapshot")?;
            let answer = ctx.call(
                "POST",
                "/api/vm/restore".into(),
                Some(json!({ "snapshotId": snapshot })),
            )?;
            merged(ctx, &answer)
        }
        "cloud.snapshot.fork" => {
            let map = args::object(raw, &["machine", "name"])?;
            let id = args::id(map, "machine")?;
            let body = named_body(map)?;
            let answer = ctx.call("POST", format!("/api/vm/{id}/fork"), Some(body))?;
            merged(ctx, &answer)
        }
        "cloud.snapshot.delete" => {
            let map = args::object(raw, &["machine", "snapshot"])?;
            let id = args::id(map, "machine")?;
            let snapshot = args::id(map, "snapshot")?;
            ctx.call("DELETE", format!("/api/vm/{id}/snapshots/{snapshot}"), None)?;
            Ok(json!({ "ok": true }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

fn named_body(map: &serde_json::Map<String, Value>) -> Result<Value, CloudError> {
    Ok(match args::text(map, "name", 128)? {
        Some(name) => json!({ "name": name }),
        None => json!({}),
    })
}
