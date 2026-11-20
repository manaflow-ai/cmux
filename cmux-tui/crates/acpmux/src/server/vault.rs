//! `_acpmux/vault_pull` and `_acpmux/vault_forget`: `machine vault pull` and
//! `forget` done by this daemon, local socket only. `_acpmux/vault_status`
//! answers `{store}`, the store this daemon keeps the values in. A machine with no usable
//! OS store keeps the vault env in the daemon's memory (`vault/store.rs`), so
//! only the daemon can pull or drop it. The reply holds names and codes only,
//! never a value.

use serde_json::{Value, json};

use super::{Conn, Origin};
use crate::rpc::{RpcError, method};

pub(super) async fn dispatch(conn: &Conn, m: &str) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_VAULT_PULL | method::MUX_VAULT_FORGET | method::MUX_VAULT_STATUS) {
        return None;
    }
    if conn.origin != Origin::Local {
        return Some(Err(RpcError::method_not_found(&format!("{m} (local socket only)"))));
    }
    if m == method::MUX_VAULT_STATUS {
        return Some(Ok(json!({"store": crate::vault::store_now().await})));
    }
    let (store, result) = if m == method::MUX_VAULT_PULL {
        crate::vault::pull_now().await
    } else {
        crate::vault::forget_now().await
    };
    Some(Ok(reply(store, &result)))
}

/// `{store, outcome?, failure?}`: what the CLI prints (`cli/host_vault.rs`).
pub(crate) fn reply(
    store: &str,
    result: &Result<crate::vault::pull::Outcome, crate::vault::pull::Failure>,
) -> Value {
    use crate::cli::host_vault::outcome_json;
    match result {
        Ok(outcome) => json!({"store": store, "outcome": outcome_json(outcome)}),
        Err(failure) => json!({
            "store": store,
            "outcome": failure.outcome.as_ref().map(outcome_json),
            "failure": {"code": failure.code, "deleted": failure.deleted},
        }),
    }
}
