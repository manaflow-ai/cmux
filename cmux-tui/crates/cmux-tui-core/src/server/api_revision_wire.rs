//! API revisions on the raw daemon protocol (cmux-api-compat, msg 2785).
//!
//! `identify` advertises `api_revision` (what this daemon speaks) and
//! `min_api_revision` (the oldest it can translate). A client declares its
//! own with `set-client-info {api_revision}`; a client that never declares
//! one is a build from before revisions and reads revision
//! [`LEGACY_API_REVISION`]. When the client is older, this daemon
//! translates: each request line is upgraded before it is parsed, and every
//! control message (responses and events) is downgraded after the other
//! outbound projections. When the client is newer, it translates for itself
//! and this daemon does nothing.
//!
//! Message kinds: `request:<cmd>`, `response:<cmd>` (matched to its request
//! by `id`), `event:<name>`. Rules live in `cmux-tui/spec/api-compat.json`;
//! `api-compat-check` makes every breaking schema change ship one.
//!
//! Not covered yet: resource API v2 lines (`cmux.protocol/2`), terminal
//! byte streams and `session.events` stream items.

use std::borrow::Cow;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, LazyLock, Mutex, PoisonError};

use cmux_api_compat::handshake::{RevisionHello, Translator, negotiate};
use cmux_api_compat::{Compat, Schema};
use serde::Deserialize;
use serde_json::Value;

use std::io::Write;

use super::{BudgetedJsonWriter, BudgetedText, MessageWriter};

/// The revision of a client that sent none (protocol 12 builds).
pub(super) const LEGACY_API_REVISION: u32 = 12;

/// Pending request ids kept for response kinds; a client that never reads
/// its replies cannot grow it past this.
const PENDING_LIMIT: usize = 4096;

/// The compiled-in revision history. Immutable data, built once.
#[allow(
    clippy::expect_used,
    reason = "compiled-in spec/api-compat.json bytes that api-compat-check validates in CI"
)]
pub(super) static API_COMPAT: LazyLock<Compat> = LazyLock::new(|| {
    let schema = Schema::from_json(include_bytes!("../../../../spec/api-compat.json"))
        .expect("spec/api-compat.json is validated by api-compat-check"); // crash-allow: compiled-in bytes that api-compat-check validates in CI
    Compat::new(schema).expect("validated schema") // crash-allow: the same compiled-in schema
});

/// The immutable revision history used by both the server and remote clients.
/// Keeping one compiled schema prevents a remote app from accepting a range it
/// cannot actually translate.
pub(super) fn compat() -> &'static Compat {
    &API_COMPAT
}

/// The `identify` fields.
pub(super) fn identify_fields() -> (u32, u32) {
    (API_COMPAT.current(), API_COMPAT.schema().base)
}

/// The refusal a too-old client reads: why, its release, and the exact
/// command for how it was installed (plans/cmux-next/tui-tester-rollout.md #4).
pub(super) fn too_old_text(why: &str, version: Option<&str>, install: Option<&str>) -> String {
    let release = version.map_or_else(String::new, |version| format!(" (cmux {version})"));
    format!(
        "this client{release} is too old for this cmux-tui daemon (cmux {}): {why}. To fix it, {}",
        crate::release::distribution_version(),
        crate::release::update_hint_for(install)
    )
}

/// What one connection negotiated.
pub(super) struct NegotiatedRevision {
    /// The revision history used to translate (the compiled-in one outside tests).
    compat: &'static Compat,
    /// The client's revision when this daemon translates for it; 0 otherwise.
    peer: AtomicU32,
    /// Request id (as JSON text) -> command, for response kinds.
    pending: Mutex<HashMap<String, String>>,
}

impl Default for NegotiatedRevision {
    fn default() -> Self {
        Self::with_compat(&API_COMPAT)
    }
}

#[derive(Deserialize)]
struct Peek {
    #[serde(default)]
    cmd: Option<String>,
    #[serde(default)]
    event: Option<String>,
    #[serde(default)]
    id: Option<Value>,
}

impl NegotiatedRevision {
    /// A connection translating with `compat` (tests pass their own history).
    pub(super) fn with_compat(compat: &'static Compat) -> Self {
        Self { compat, peer: AtomicU32::new(0), pending: Mutex::new(HashMap::new()) }
    }

    /// Records the client's declared revision. Errors when this daemon can
    /// talk to neither it nor any revision it can translate.
    pub(super) fn declare(&self, client_revision: u32) -> anyhow::Result<()> {
        let (current, base) = (self.compat.current(), self.compat.schema().base);
        let negotiated = negotiate(
            RevisionHello { api_revision: current, min_api_revision: base },
            Some(RevisionHello { api_revision: client_revision, min_api_revision: client_revision }),
            LEGACY_API_REVISION,
        )
        .or_else(|_| {
            // A newer client with a higher floor still translates for itself
            // as long as it can reach our revision.
            if client_revision > current {
                Ok(cmux_api_compat::handshake::Negotiated {
                    ours: current,
                    peer: client_revision,
                    translator: Translator::Peer,
                })
            } else {
                Err(anyhow::anyhow!(
                    "api_revision {client_revision} is older than this daemon can translate ({base}..={current})"
                ))
            }
        })?;
        let peer = if negotiated.translator == Translator::Us { client_revision } else { 0 };
        self.peer.store(peer, Ordering::Release);
        Ok(())
    }

    fn peer(&self) -> Option<u32> {
        match self.peer.load(Ordering::Acquire) {
            0 => None,
            rev => Some(rev),
        }
    }

    /// Upgrades one request line from the client's revision.
    pub(super) fn upgrade_request<'a>(&self, message: &'a str) -> Cow<'a, str> {
        let Some(peer) = self.peer() else { return Cow::Borrowed(message) };
        let Ok(peek) = serde_json::from_str::<Peek>(message) else { return Cow::Borrowed(message) };
        let Some(cmd) = peek.cmd else { return Cow::Borrowed(message) };
        if let Some(id) = &peek.id {
            let mut pending = self.pending.lock().unwrap_or_else(PoisonError::into_inner);
            if pending.len() >= PENDING_LIMIT {
                pending.clear();
            }
            pending.insert(id.to_string(), cmd.clone());
        }
        let kind = format!("request:{cmd}");
        match self.compat.translate(&kind, peer, self.compat.current(), message.as_bytes()) {
            Ok(Cow::Borrowed(_)) | Err(_) => Cow::Borrowed(message),
            Ok(Cow::Owned(bytes)) => {
                String::from_utf8(bytes).map_or(Cow::Borrowed(message), Cow::Owned)
            }
        }
    }

    /// The message kind of an outbound control line, consuming its pending
    /// request id when it is a response.
    fn outbound_kind(&self, text: &str) -> Option<String> {
        let peek = serde_json::from_str::<Peek>(text).ok()?;
        if let Some(event) = peek.event {
            return Some(format!("event:{event}"));
        }
        let id = peek.id?;
        let cmd =
            self.pending.lock().unwrap_or_else(PoisonError::into_inner).remove(&id.to_string())?;
        Some(format!("response:{cmd}"))
    }

    /// Downgrades one outbound control line to the client's revision.
    /// `None` when the line is unchanged.
    fn downgrade(&self, text: &str) -> Option<Vec<u8>> {
        let peer = self.peer()?;
        let kind = self.outbound_kind(text)?;
        let program = self.compat.program(&kind, self.compat.current(), peer).ok()?;
        if program.is_identity() {
            return None;
        }
        program.rewrite(text.as_bytes()).ok().map(Cow::into_owned)
    }
}

impl MessageWriter {
    /// The last outbound projection: the client's API revision.
    pub(super) fn project_api_revision(
        &self,
        text: Arc<BudgetedText>,
    ) -> std::io::Result<Arc<BudgetedText>> {
        let Some(bytes) = self.api_revision.downgrade(&text) else { return Ok(text) };
        // The rewriter already wrote JSON: charge it to the control budget as is.
        let mut writer = BudgetedJsonWriter::new(self.render_service.control_budget.clone());
        writer.write_all(&bytes)?;
        Ok(writer.finish())
    }
}

#[cfg(test)]
#[path = "api_revision_wire_tests.rs"]
mod tests;
