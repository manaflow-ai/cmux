//! `cloud.snapshot.*` over `cmux.wire/1`: list (one machine or the team),
//! create, restore (a new machine), delete. Fork is gone: a restore makes
//! the new machine.

use super::machine::{deleted, machine_mutation, trimmed};
use crate::api::args;
use crate::api::models::check_revision;
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer};
use cmux_cloud_wire::{CloudSnapshotCreateOp, CloudSnapshotListOp, Op};
use serde_json::{Value, json};

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.snapshot.list" => {
            let map = args::object(raw, &["machine"])?;
            args::opt_id(map, "machine")?;
            let mut list: <CloudSnapshotListOp as Op>::Result =
                decode_answer(name, ctx.wire(name, args::params(map, &["machine"]))?.value)?;
            for snapshot in &mut list.snapshots {
                check_revision(name, &mut snapshot.revision)?;
            }
            Ok(json!({ "snapshots": list.snapshots }))
        }
        "cloud.snapshot.create" => {
            let map = args::object(raw, &["machine", "name"])?;
            args::id(map, "machine")?;
            args::text(map, "name", 80)?;
            let mut answer: <CloudSnapshotCreateOp as Op>::Result = decode_answer(
                name,
                ctx.wire(name, args::params(map, &["machine", "name"]))?.value,
            )?;
            check_revision(name, &mut answer.snapshot.revision)?;
            Ok(json!({ "snapshot": answer.snapshot }))
        }
        "cloud.snapshot.restore" => {
            let map = args::object(raw, &["snapshot", "name"])?;
            args::id(map, "snapshot")?;
            args::name(map, "name")?;
            machine_mutation(ctx, name, trimmed(map, &["snapshot", "name"]))
        }
        "cloud.snapshot.delete" => {
            let map = args::object(raw, &["snapshot"])?;
            args::id(map, "snapshot")?;
            deleted(&ctx.wire(name, args::params(map, &["snapshot"]))?.value)?;
            Ok(json!({ "deleted": true }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}
