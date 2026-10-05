//! `browser-host-provider` (`browser-host-provider-v1`; plans/cmux-next/
//! browser-host.md, step c2): the credentials the cmux app needs to dial its
//! daemon's browser host as the provider, `{socket, secret, host_pid}`.
//!
//! Only the verified local app gets them: a connection on the daemon's Unix
//! socket whose `client-hello` declared role `main` and passed a proof (the
//! app's code signature or its install-key hello; server/client_hello.rs).
//! Everything else is refused with `origin.forbidden`: a connection without
//! a hello (agents in terminals), an unproven `main`, a page relay (page
//! JavaScript; also with a confirmed `user` claim, which the v1 path does not
//! take), a WebSocket client and a remote client (refused earlier by the
//! remote relay's allowlist). The secret is in the reply only; it is never
//! logged, journaled or put in an event.

use serde_json::{Value, json};

use super::Mux;

/// The code when the caller may have the credentials but no host runs.
const ENGINE_UNAVAILABLE: &str = "engine_unavailable";

/// A refused or failed `browser-host-provider`; its `code` is the legacy
/// `error_code`. The message never carries the secret.
#[derive(Debug)]
pub(super) struct ProviderRefused {
    code: &'static str,
    message: String,
}

impl std::fmt::Display for ProviderRefused {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ProviderRefused {}

/// The legacy `error_code` of a refused or failed `browser-host-provider`.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<ProviderRefused>().map(|refused| refused.code.to_string())
}

pub(super) fn run(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    let _ = client;
    let credentials = mux
        .control_clients
        .browser_host
        .credentials()
        .map_err(|message| ProviderRefused { code: ENGINE_UNAVAILABLE, message })?;
    Ok(json!({
        "socket": credentials.socket.display().to_string(),
        "secret": credentials.secret,
        "host_pid": credentials.host_pid,
    }))
}

#[cfg(all(test, unix))]
#[path = "browser_host_provider_tests.rs"]
mod tests;
