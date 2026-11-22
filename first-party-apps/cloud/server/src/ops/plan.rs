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

/// The checkout URL the host opens in the browser: `https://` with a
/// host, no user info (`user@` can disguise the real host), no whitespace
/// or control characters, at most 4096 bytes.
fn checked_checkout_url(url: &str) -> Result<&str, CloudError> {
    let bad = |why: &str| CloudError::new(codes::BAD_RESPONSE, format!("checkout URL: {why}"));
    let rest = url.strip_prefix("https://").ok_or_else(|| bad("not https"))?;
    if url.len() > 4096 || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err(bad("too long or has whitespace or control characters"));
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    if authority.is_empty() || authority.contains('@') {
        return Err(bad("no host, or user info before the host"));
    }
    Ok(url)
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
            Ok(json!({ "url": checked_checkout_url(&checkout.url)? }))
        }
        _ => Err(CloudError::new(codes::UNKNOWN_OP, format!("{name} has no handler"))),
    }
}

#[cfg(test)]
mod tests {
    use super::checked_checkout_url;

    #[test]
    fn only_a_plain_https_url_with_a_host_is_opened() {
        assert!(checked_checkout_url("https://checkout.stripe.com/c/pay/cs_test_1").is_ok());
        for bad in [
            "http://checkout.stripe.com/x",
            "https://",
            "https:///path",
            "https://user:pass@checkout.stripe.com/x",
            "https://user@checkout.stripe.com/x",
            "https://checkout.stripe.com/a b",
            "https://checkout.stripe.com/\u{7}",
            "javascript:alert(1)",
        ] {
            assert!(checked_checkout_url(bad).is_err(), "{bad:?}");
        }
        assert!(checked_checkout_url(&format!("https://a.com/{}", "x".repeat(5000))).is_err());
    }
}
