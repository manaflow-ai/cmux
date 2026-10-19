//! A credential provider can end its own servers' scope; no caller-supplied ID grants authority.
use super::provider::{ProviderClaim, hosting_app_connection};
use super::relay::RELAY_SCOPE_OP;
use super::servers::line;
use super::supervisor::{ApiError, Inner, Out, Supervisor};
use serde_json::{Value, json};

impl Supervisor {
    pub fn provider_scope_changed(
        &self,
        client: u64,
        claim: ProviderClaim,
    ) -> Result<Value, ApiError> {
        if !hosting_app_connection(&claim) {
            return Err(ApiError::new(
                "apps.provider.forbidden",
                "only the verified app ends its credential scope",
            ));
        }
        let mut inner = self.inner.lock().unwrap();
        if inner.providers.get("credential") != Some(&client) {
            return Err(ApiError::new(
                "apps.provider.unknown",
                "this connection does not own the credential provider",
            ));
        }
        let (servers, outs) = self.end_credential_scope_locked(&mut inner);
        drop(inner);
        self.emit(outs);
        Ok(json!({"servers": servers}))
    }

    /// Close terminal handoffs now, cancel pending work, then drain the owned server process.
    /// Older servers also receive EOF, so ignoring the notice cannot retain a usable server.
    pub(super) fn end_credential_scope_locked(&self, inner: &mut Inner) -> (usize, Vec<Out>) {
        let apps: Vec<String> = inner
            .catalog
            .packages
            .keys()
            .filter(|app| Self::host_op_allowed(inner, app, RELAY_SCOPE_OP))
            .cloned()
            .collect();
        let mut servers = 0;
        let mut outs = Vec::new();
        for app in &apps {
            super::open_tokens::forget_open_tokens(inner, app);
            if inner.servers.get(app).is_none_or(|server| server.stopping) {
                continue;
            }
            servers += 1;
            inner.servers[app].process.send(line(&json!({"type": "scope.invalidate"})));
            outs.extend(self.terminal_server_gone_locked(inner, app));
            outs.extend(self.stop_server_locked(inner, app, "credential scope changed"));
        }
        (servers, outs)
    }
}
