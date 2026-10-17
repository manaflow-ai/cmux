//! A cached, non-secret projection for machine inventory consumers. Unlike
//! the health control endpoint, this view never checks, rescans or updates.

use serde_json::{Value, json};

use super::{HarnessHealth, probe};
use crate::rpc::RpcError;

/// Select fields individually: health diagnostics include paths, commands
/// and arbitrary CLI output, and new health fields are private by default.
pub(crate) fn view(rows: &[HarnessHealth], params: &Value) -> Result<Value, RpcError> {
    let valid = params.as_object().is_some_and(|fields| {
        fields.len() == 1 && fields.get("view").and_then(Value::as_str) == Some("inventory")
    });
    if !valid {
        return Err(RpcError::invalid_params(
            "the cached inventory accepts only {view: inventory}; health controls and machine selectors are not accepted",
        ));
    }
    let harnesses: Vec<Value> = rows
        .iter()
        .filter(|row| safe_id(&row.id))
        .map(|row| {
            let version = safe_version(row.version.as_deref());
            let latest = safe_version(row.latest.as_deref());
            json!({
                "id": row.id,
                "channel": row.channel,
                "version": version,
                "latest": latest,
                "latestCheckedAt": row.latest_checked_at,
                "outdated": row.outdated && version.is_some() && latest.is_some(),
                "auth": row.auth,
                "checkedAt": row.checked_at,
            })
        })
        .collect();
    Ok(json!({"view": "inventory", "cached": true, "harnesses": harnesses}))
}

fn safe_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
}

/// A saved cache may predate version parsing. Only a complete version
/// token crosses this boundary; never an error line containing one.
fn safe_version(value: Option<&str>) -> Option<&str> {
    value.filter(|v| v.len() <= 64 && probe::parse_version(v).as_deref() == Some(*v))
}
