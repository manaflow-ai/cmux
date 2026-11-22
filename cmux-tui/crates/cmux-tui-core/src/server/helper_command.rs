//! cmux Helper's daemon commands (`helper-v1`; docs/cmux-helper.md):
//!
//! - `helper-status`: cmux Helper's Screen Recording and Accessibility
//!   (`permissions`) and its System Settings name (`name`), once the app
//!   reported them, and, for the verified app, the Computer Use worker's
//!   status. Any local Unix connection.
//! - `helper-config {permissions, name}`: the helper's grants and name as the
//!   verified app read them from the helper (memory only).

use serde_json::Value;

use super::{ClientTransport, Mux};
use crate::request_origin::{HelloRole, RequestOrigin};

const ORIGIN_FORBIDDEN: &str = "origin.forbidden";

#[derive(Debug)]
pub(super) struct HelperRefused {
    code: &'static str,
    message: String,
}

impl std::fmt::Display for HelperRefused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for HelperRefused {}

pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<HelperRefused>().map(|refused| refused.code.to_string())
}

/// Who is asking: a local Unix connection, and whether it is the verified app.
pub(super) struct Caller {
    pub(super) verified_app: bool,
}

pub(super) fn caller(mux: &Mux, client: u64) -> Result<Caller, HelperRefused> {
    let state = mux.control_clients.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let record = state
        .clients
        .get(&client)
        .ok_or_else(|| forbidden("needs a registered local connection"))?;
    if !matches!(record.transport, ClientTransport::Unix) {
        return Err(forbidden("needs a local Unix socket connection"));
    }
    if record.origin.derive() == RequestOrigin::Page {
        return Err(forbidden("is not available to pages"));
    }
    Ok(Caller { verified_app: record.origin.role == HelloRole::Main && record.origin.verified_app })
}

fn forbidden(reason: &str) -> HelperRefused {
    HelperRefused { code: ORIGIN_FORBIDDEN, message: format!("cmux Helper {reason}") }
}

pub(super) fn status(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    let caller = caller(mux, client)?;
    let mut status = mux.control_clients.helper.status();
    // Settings reads the on-demand supervisor without starting its worker or requesting its secret.
    let computer_use = &mux.control_clients.computer_use;
    if caller.verified_app
        && computer_use.configured()
        && let Some(fields) = status.as_object_mut()
    {
        fields.insert("computer_use".into(), computer_use.status());
    }
    Ok(status)
}

pub(super) fn config(
    mux: &Mux,
    client: u64,
    permissions: Option<crate::helper::HelperPermissions>,
    name: Option<String>,
) -> anyhow::Result<Value> {
    if !caller(mux, client)?.verified_app {
        return Err(forbidden("grants are reported by the cmux app").into());
    }
    Ok(mux.control_clients.helper.report(permissions, name))
}
