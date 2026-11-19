//! Cloud start traces (`cloud.start_trace.get`, `cloud.start_trace.list`):
//! where one machine start spent its time, hop by hop. Reads of the team's
//! CloudDO; the answer is the platform's body verbatim (the webview's
//! waterfall panel draws it). DEV and NIGHTLY only: `Server::run` answers
//! `cmux.cloud.unsupported` on a release build before any wire call.

use crate::api::args;
use crate::api::{CloudError, ControlPlane, Ctx, codes};
use serde_json::Value;

/// A trace id: `^[A-Za-z0-9_-]{8,80}$` (the create's trace, else its key).
fn check_trace(map: &serde_json::Map<String, Value>) -> Result<(), CloudError> {
    let ok = map.get("trace").and_then(Value::as_str).is_some_and(|trace| {
        (8..=80).contains(&trace.len())
            && trace.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    });
    if ok {
        Ok(())
    } else {
        Err(CloudError::invalid("trace is required: 8 to 80 of A-Z, a-z, 0-9, _ and -"))
    }
}

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    let params = match name {
        "cloud.start_trace.get" => {
            let map = args::object(raw, &["trace"])?;
            check_trace(map)?;
            args::params(map, &["trace"])
        }
        "cloud.start_trace.list" => {
            let map = args::object(raw, &["since_ms", "limit"])?;
            args::int(map, "since_ms", 0, i64::MAX, 1)?;
            args::int(map, "limit", 1, 200, 1)?;
            args::params(map, &["since_ms", "limit"])
        }
        _ => return Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    };
    let value = ctx.wire(name, params)?.value;
    if !value.is_object() {
        return Err(CloudError::new(
            codes::BAD_RESPONSE,
            format!("{name}: the answer is not an object"),
        ));
    }
    Ok(value)
}
