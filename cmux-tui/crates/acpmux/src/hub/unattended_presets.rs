//! Part of `Hub`; see `hub/mod.rs`. A no-prompt preset the person approved once runs the chats
//! agents start from it on another machine with no one watching (Leo, 2026-11-09: "A no-prompt
//! preset approved once in the cmux app would let those sessions run without anyone watching."
//! "yeah we should have that too").
//!
//! Before this, a chat an agent below full access started on a peer ran under `ask` there (the
//! peer's remote guard), whatever its preset's policy, and its first tool call waited on a prompt
//! only the person's app could answer: a handed-off chat stopped on its first command.
//!
//! - A no-prompt preset is one whose policy settles every tool call with no person, approve-all
//!   or review ([`crate::config::Preset::policy_skips_asking`]): approve-reads and approve-edits
//!   still ask for the rest, so such a chat would still wait. Only the person sets such a policy
//!   (`hub/person.rs`), and only the person approves it: `_acpmux/presets {name, approveMode:
//!   true}` records the digest of the preset's contents (`Preset::approval_digest`, as for a
//!   mode, (b) in `hub/person.rs`). An approval counts only while the contents still hash to it,
//!   so any change to the preset drops it.
//! - A `session/new` this daemon forwards to a peer from a proven caller session
//!   ([`Hub::forward_unattended_preset`]) that names a preset of THIS daemon and no harness,
//!   model, effort, policy, mode or env of its own:
//!   - approved: the forwarded start carries the preset's harness, model, effort and policy in
//!     place of its name, so the peer needs no copy of it and starts the chat under that policy
//!     (a proven peer may start one, `full_access_children.rs`; a peer that refuses says so,
//!     `refused_by`). A preset with an env, args or a system prompt is refused instead: those are
//!     this machine's and never cross to another;
//!   - not approved: refused before anything starts, and the caller's chat gets a
//!     `preset_approval_request` record `{preset, digest, harness, model, effort, policy, host,
//!     description}`, which the app shows as a card. Its Approve sends `_acpmux/presets {name,
//!     approveMode: true, approveDigest, sessionId}` from the person's connection; Not now sends
//!     `approveMode: false`. The write counts only when `approveDigest` is the preset's digest
//!     now (an edit since the card was shown approves nothing), and then records
//!     `preset_approval_decision {preset, digest, outcome}` in that chat, which closes the card.
//!     The agent starts again once it is approved.
//!   - unchanged: a start with no proven caller (the CLI outside any chat), one whose starter
//!     runs in full access (it gets approve-all there anyway), and a preset this daemon does not
//!     have, are forwarded as before: the peer resolves the name.
//! - A start on this machine is unchanged: it already takes a preset's policy when its starter's
//!   limits do not apply (`lifecycle.rs`), and `holdAgentStartsToStarter` keeps holding it.

use super::*;
use cmux_json::JsonSet as _;

/// `error.data.reason` of a forwarded start refused until the person approves its preset.
pub(crate) const APPROVAL_REQUIRED: &str = "preset.approval_required";

/// The fields of a `session/new` that, named by the request itself, keep a preset's approval
/// from applying: the approval covers the preset's own contents, nothing the agent adds.
const OWN_FIELDS: [&str; 8] =
    ["harness", "model", "effort", "policy", "mode", "env", "route", "adopt"];

impl Hub {
    /// The `session/new` `p` this daemon forwards to peer `host` for proven caller `caller`
    /// (module docs): an approved no-prompt preset of this daemon expanded in place of its name,
    /// or the refusal that asks the person for its approval. Anything else is left as it is.
    /// Returns the expanded preset's name and approved digest, which
    /// [`Hub::unattended_preset_holds`] checks again right before the start is sent.
    pub(crate) async fn forward_unattended_preset(
        &self,
        caller: Option<&str>,
        host: &str,
        p: &mut Value,
    ) -> Result<Option<(String, String)>, RpcError> {
        let Some(s) = caller.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id)) else {
            return Ok(None);
        };
        // A starter in full access already starts its chats there in full access.
        if self.starter_runs_full_access(caller) {
            return Ok(None);
        }
        let meta = p.pointer("/_meta/acpmux");
        let field = |k: &str| {
            meta.and_then(|m| m.get(k))
                .filter(|v| !v.is_null())
                .or(p.get(k).filter(|v| !v.is_null()))
        };
        let Some(name) = field("preset").and_then(Value::as_str).map(str::to_owned) else {
            return Ok(None);
        };
        if OWN_FIELDS.iter().any(|k| field(k).is_some()) {
            return Ok(None);
        }
        let Some(preset) = self.config.read().await.presets.get(&name).cloned() else {
            return Ok(None);
        };
        if !preset.policy_skips_asking() {
            return Ok(None);
        }
        if !preset.policy_approved() {
            let card = json!({
                "preset": name,
                "digest": preset.approval_digest(),
                "harness": preset.harness,
                "model": preset.model,
                "effort": preset.effort,
                "policy": preset.policy,
                "host": host,
                "description": preset.description,
            });
            self.append(&s, "mux", "preset_approval_request", card);
            return Err(RpcError::new(
                -32000,
                format!(
                    "preset {name} runs chats without asking, so it starts one on {host} only once the person approves it: a card to approve it waits in this chat in cmux NEXT; start again after"
                ),
            )
            .with_data(json!({"reason": APPROVAL_REQUIRED, "preset": name, "host": host})));
        }
        if !preset.env.is_empty() || preset.shapes_command() {
            return Err(RpcError::invalid_params(format!(
                "preset {name} sets an env, args or a system prompt, which stay on this machine: a preset that starts unattended chats on {host} sets only harness, model, effort and policy"
            )));
        }
        for k in ["preset", "policy", "harness", "model", "effort", "mode"] {
            if let Some(o) = p.as_object_mut() {
                o.remove(k);
            }
            if let Some(o) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
                o.remove(k);
            }
        }
        let policy = preset.policy.map(|v| v.to_string());
        for (k, v) in [
            ("harness", Some(preset.harness)),
            ("model", preset.model),
            ("effort", preset.effort),
            ("policy", policy),
        ] {
            if let Some(v) = v {
                p.set_path(&["_meta", "acpmux", k], json!(v));
            }
        }
        Ok(preset.mode_approval.map(|d| (name, d)))
    }

    /// Whether preset `name` still has the approved contents `digest` (the person may have edited
    /// it while the forward was made): the last check before the start leaves for the peer
    /// (`server/requests.rs`). An edit that lands after it is the same as one right after the
    /// start: it covers the next start, not the one already sent.
    pub(crate) async fn unattended_preset_holds(
        &self,
        name: &str,
        digest: &str,
    ) -> Result<(), RpcError> {
        let cfg = self.config.read().await;
        let holds = cfg.presets.get(name).is_some_and(|p| {
            p.policy_approved()
                && p.approval_digest().is_some_and(|d| cmux_local_auth::tokens_match(&d, digest))
        });
        if holds {
            Ok(())
        } else {
            Err(RpcError::new(
                -32000,
                format!("preset {name} changed while this start was made; nothing was started, start again"),
            )
            .with_data(json!({"reason": APPROVAL_REQUIRED, "preset": name})))
        }
    }

    /// The person's answer to a chat's approval card (module docs): `preset_approval_decision` in
    /// the chat `params.sessionId` names, for the digest the card showed. A write that names no
    /// chat or digest, or that is not the person's, records nothing (`server/requests/presets.rs`).
    pub(crate) fn close_preset_card(&self, params: &Value, name: &str, approved: bool) {
        let digest = params.get("approveDigest").and_then(Value::as_str);
        let session = params.get("sessionId").and_then(Value::as_str);
        let (Some(digest), Some(id)) = (digest, session) else { return };
        let Ok(s) = self.resolve(id) else { return };
        let outcome = if approved { "approved" } else { "declined" };
        self.append(
            &s,
            "mux",
            "preset_approval_decision",
            json!({"preset": name, "digest": digest, "outcome": outcome}),
        );
    }
}
