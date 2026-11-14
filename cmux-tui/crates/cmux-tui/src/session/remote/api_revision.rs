//! Client-side API revision negotiation for older remote cmux-tui daemons.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};

use anyhow::Context;
use cmux_api_compat::Compat;
use cmux_api_compat::handshake::{Negotiated, RevisionHello, Translator, negotiate};
use serde_json::Value;

/// The revision translator for one remote connection.
pub(super) struct RemoteApiRevision {
    compat: &'static Compat,
    negotiated: Negotiated,
    commands: Mutex<HashMap<u64, String>>,
}

const PENDING_COMMAND_LIMIT: usize = 4096;

impl RemoteApiRevision {
    /// Negotiate from the server's `identify` response. Older servers omit the
    /// fields and are handled by the legacy protocol path.
    pub(super) fn from_identity(ident: &Value) -> anyhow::Result<Option<Self>> {
        Self::with_compat(cmux_tui_core::server::api_revision_compat(), ident)
    }

    fn with_compat(compat: &'static Compat, ident: &Value) -> anyhow::Result<Option<Self>> {
        let Some(current) = ident.get("api_revision") else {
            return Ok(None);
        };
        let current = current.as_u64().context("remote api_revision must be an integer")?;
        let current = u32::try_from(current).context("remote api_revision is too large")?;
        let minimum = ident
            .get("min_api_revision")
            .map(|value| {
                let value = value.as_u64().context("remote min_api_revision must be an integer")?;
                u32::try_from(value).context("remote min_api_revision is too large")
            })
            .transpose()?
            .unwrap_or(current);
        anyhow::ensure!(minimum <= current, "remote API revision range is inverted");
        let ours = RevisionHello::ours(compat);
        let peer = RevisionHello { api_revision: current, min_api_revision: minimum };
        let negotiated = negotiate(ours, Some(peer), ours.min_api_revision)
            .map_err(|error| anyhow::anyhow!("API revision ranges do not overlap: {error}"))?;
        Ok(Some(Self { compat, negotiated, commands: Mutex::new(HashMap::new()) }))
    }

    pub(super) fn local_revision(&self) -> u32 {
        self.negotiated.ours
    }

    /// Rewrites a request for an older peer and records its command for the
    /// response's message kind.
    pub(super) fn outgoing(&self, id: u64, command: &str, message: &str) -> anyhow::Result<String> {
        let rewritten = self.rewrite_outgoing(command, message)?;
        if self.negotiated.translator != Translator::Us {
            return Ok(rewritten);
        }
        {
            let mut commands = self.commands.lock().unwrap_or_else(PoisonError::into_inner);
            anyhow::ensure!(
                commands.len() < PENDING_COMMAND_LIMIT,
                "too many pending API requests"
            );
            commands.insert(id, command.to_owned());
        }
        Ok(rewritten)
    }

    pub(super) fn forget(&self, id: u64) {
        self.commands.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
    }

    /// Rewrites a fire-and-forget request without retaining an id for a reply
    /// that the session deliberately does not consume.
    pub(super) fn outgoing_no_reply(&self, command: &str, message: &str) -> anyhow::Result<String> {
        self.rewrite_outgoing(command, message)
    }

    fn rewrite_outgoing(&self, command: &str, message: &str) -> anyhow::Result<String> {
        let kind = format!("request:{command}");
        let rewritten = self
            .negotiated
            .outgoing(self.compat, &kind, message.as_bytes())
            .map_err(|error| anyhow::anyhow!("cannot translate {kind}: {error}"))?;
        String::from_utf8(rewritten.into_owned())
            .context("API compatibility translation produced invalid UTF-8")
    }

    /// Rewrites a response or event from an older peer into this client's
    /// native revision.
    pub(super) fn incoming(&self, message: &str) -> anyhow::Result<String> {
        if self.negotiated.translator != Translator::Us {
            return Ok(message.to_owned());
        }
        let value: Value =
            serde_json::from_str(message).context("remote API message is not JSON")?;
        let kind = if let Some(event) = value.get("event").and_then(Value::as_str) {
            format!("event:{event}")
        } else if let Some(id) = value.get("id").and_then(Value::as_u64) {
            let command = self.commands.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            let Some(command) = command else { return Ok(message.to_owned()) };
            format!("response:{command}")
        } else {
            return Ok(message.to_owned());
        };
        let rewritten = self
            .negotiated
            .incoming(self.compat, &kind, message.as_bytes())
            .map_err(|error| anyhow::anyhow!("cannot translate {kind}: {error}"))?;
        String::from_utf8(rewritten.into_owned())
            .context("API compatibility translation produced invalid UTF-8")
    }
}

#[cfg(test)]
mod tests;
