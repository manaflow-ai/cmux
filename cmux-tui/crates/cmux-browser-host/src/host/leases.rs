//! `browser.repl.leases` (RFD 0125 D7.2): the person's side (user origin:
//! the app, or the daemon that keeps the `browser_grants` rows) hands an
//! open session the live grants it holds on the person's profile. From then
//! on the session reaches only its leased sites; `{leases: null}` returns it
//! to its domain policy alone. Agent code never sets its own leases.

use cmux_browser_grants::{Lease, Leases, Tier};
use serde_json::{Value, json};

use super::{Caller, Host};
use crate::protocol::{DriverError, ErrorCode};

const OP: &str = "browser.repl.leases";

impl Host {
    pub(super) fn set_leases(&self, caller: &Caller, params: &Value) -> Result<Value, DriverError> {
        if caller.origin != "user" {
            return Err(DriverError::new(
                ErrorCode::Forbidden,
                format!("{OP}: only the person lends a sign-in (a browser grant)"),
            ));
        }
        let name = Self::session_name(params)?;
        let leases = match params.get("leases") {
            None => {
                return Err(DriverError::invalid(format!("{OP}: leases: expected a list or null")));
            }
            Some(Value::Null) => None,
            Some(list) => Some(parse_leases(list)?),
        };
        let session = self
            .sessions()
            .get(&name)
            .cloned()
            .ok_or_else(|| DriverError::invalid(format!("{OP}: no session {name}")))?;
        let count = leases.as_ref().map(|leases| leases.0.len());
        session.gate.set_leases(leases)?;
        Ok(json!({"session": name, "leases": count}))
    }
}

/// `[{site, tier, expiresAt}]`: a site is normalized to its registrable
/// domain; a bare public suffix is refused.
fn parse_leases(list: &Value) -> Result<Leases, DriverError> {
    let invalid = |message: String| DriverError::invalid(format!("{OP}: {message}"));
    let items = list.as_array().ok_or_else(|| invalid("leases: expected a list or null".into()))?;
    let mut leases = Vec::with_capacity(items.len());
    for item in items {
        let site = item.get("site").and_then(Value::as_str).unwrap_or("");
        let site = cmux_browser_grants::grant_site(site).map_err(|e| invalid(e.0))?;
        let tier = Tier::parse(item.get("tier").and_then(Value::as_str).unwrap_or(""))
            .map_err(|e| invalid(e.0))?;
        let expires_at_ms = item
            .get("expiresAt")
            .and_then(Value::as_u64)
            .ok_or_else(|| invalid("expiresAt: expected milliseconds since the epoch".into()))?;
        leases.push(Lease { site, tier, expires_at_ms });
    }
    Ok(Leases(leases))
}

#[cfg(test)]
#[path = "leases_tests.rs"]
mod tests;
