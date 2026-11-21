use crate::api::{CloudError, ControlPlane, Ctx, args, decode_answer};
use cmux_cloud_wire::{CloudSurgePreviewOp, Op};
use serde_json::{Value, json};

pub(super) fn preview<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    let map = args::object(raw, &["count", "ttl_seconds"])?;
    let count = args::int(map, "count", 1, 8, 1)?
        .ok_or_else(|| CloudError::invalid("count is required"))?;
    let ttl = args::int(map, "ttl_seconds", 300, 3600, 1)?
        .ok_or_else(|| CloudError::invalid("ttl_seconds is required"))?;
    let result: <CloudSurgePreviewOp as Op>::Result =
        decode_answer(name, ctx.wire(name, json!({ "count": count, "ttl_seconds": ttl }))?.value)?;
    Ok(json!(result))
}
