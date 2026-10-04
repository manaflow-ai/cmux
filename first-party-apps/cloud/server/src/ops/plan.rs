//! `cloud.plan.get` (limits and usage in one record; `cloud.usage.get`
//! folded in) and `cloud.billing.checkout` (a checkout URL the host opens in
//! the browser; no card data in cmux). The backend reads the plan from the
//! billing owner; the server computes no limit itself (contract 1.5).

use crate::api::args;
use crate::api::models::Plan;
use crate::api::{CloudError, ControlPlane, Ctx, codes, decode_answer};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct Checkout {
    url: String,
}

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    match name {
        "cloud.plan.get" => {
            args::object(raw, &[])?;
            let plan: Plan = decode_answer(name, ctx.wire(name, json!({}))?.value)?;
            Ok(json!(plan))
        }
        "cloud.billing.checkout" => {
            let map = args::object(raw, &["plan"])?;
            args::id(map, "plan")?;
            let checkout: Checkout =
                decode_answer(name, ctx.wire(name, args::params(map, &["plan"]))?.value)?;
            // The host opens it in the browser: only an https URL.
            if !checkout.url.starts_with("https://") {
                return Err(CloudError::new(codes::BAD_RESPONSE, "the checkout URL is not https"));
            }
            Ok(json!({ "url": checkout.url }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}
