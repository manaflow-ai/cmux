//! A chat cmux-next starts on another machine (a peer link, a Cloud VM, a headless daemon)
//! follows the answer of the Mac that started it to "should agents you start in cmux get cmux's
//! tools?" (`agents.cmuxMcp`, on by default), not that machine's own: the person set it on the
//! Mac they use. A machine's own answer applies to the chats started there.
//!
//! The daemon that forwards a `session/new` to a peer (`_meta.acpmux.peer`) sends its own answer
//! as `_meta.acpmux.cmuxTools` (`on` or `off`; a peer start with neither runs `off`). The peer
//! takes it only from a peer daemon's connection (its peer token or carrier; never a Web client
//! or a paired device) and
//! records it in the session's own env as [`TOOLS_ANSWER_ENV`]. Every spawn applies that env, so
//! the session's tool list (`AgentTools::scoped`) and any `cmux mcp serve` the chat starts (the
//! `cmux` server, or a person's own entry: `cli/mcp.rs` `refusal`) use it. A fork or a sub-session
//! of the chat keeps it.
//!
//! A session started over a remote-origin connection gets none of cmux's agent tool servers at all
//! (`agent_tools::left_out`), so on a peer the answer decides only what a `cmux mcp serve` the
//! chat starts by other means answers: the off server, or cmux's tools. Like the answer itself, it
//! is a consent gate for the person's agents, not a security boundary.

use std::collections::BTreeMap;

use serde_json::{Value, json};

pub use crate::agent_tools::TOOLS_ANSWER_ENV;

/// The `_meta.acpmux` field a forwarded `session/new` carries.
pub const FIELD: &str = "cmuxTools";

/// The answer a `session/new` brought from the daemon that forwarded it: only over a peer
/// daemon's own connection (`ConnAuth::peer_daemon`), or a start the hub relayed from a stamped
/// daemon (`ConnAuth::MeshControl`; `mesh_relay.rs` drops it from a start of no daemon).
pub fn asked(auth: crate::server::ConnAuth, params: &Value) -> Option<&'static str> {
    if !auth.peer_daemon() && auth != crate::server::ConnAuth::MeshControl {
        return None;
    }
    // A peer daemon forwarding for a Web client of its own (`via: web`): that client's request,
    // not the Mac's, as `vm_boundary::forwards` holds it.
    if params.pointer("/_meta/acpmux/via").and_then(Value::as_str) == Some("web") {
        return None;
    }
    match params.pointer(&format!("/_meta/acpmux/{FIELD}")).and_then(Value::as_str) {
        Some("on") => Some("on"),
        Some("off") => Some("off"),
        _ => None,
    }
}

/// This daemon's answer, as a forwarded `session/new` sends it: `on`, else `off`.
pub fn here(settings: Option<&str>) -> &'static str {
    if crate::agent_tools::agents_get_cmux(settings) { "on" } else { "off" }
}

/// [`here`] for the forwarded request `params`: `off` when its harness (`_meta.acpmux.harness`,
/// `harness` or `agent`) is an agent the person switched off on this Mac (cmux#49395).
pub fn here_for(settings: Option<&str>, params: &Value) -> &'static str {
    let harness = ["/_meta/acpmux/harness", "/harness", "/agent"]
        .iter()
        .find_map(|pointer| params.pointer(pointer).and_then(Value::as_str));
    let agent = harness.and_then(crate::agent_tools::switch_agent);
    if agent.is_some_and(|agent| crate::agent_tools::agent_switched_off(settings, agent)) {
        "off"
    } else {
        here(settings)
    }
}

/// Stamps a `session/new` this daemon forwards to a peer with `answer` (this daemon's, [`here`]),
/// over whatever its caller sent.
pub fn stamp(params: &mut Value, answer: &str) {
    crate::hub::merge_mux_meta(params, json!({FIELD: answer}));
}

/// A fork's or sub-session's own env with its parent's answer, when the parent has one and the
/// request did not set it.
pub fn inherited(
    mut env: BTreeMap<String, String>,
    parent: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    if let Some(answer) = parent.get(TOOLS_ANSWER_ENV) {
        env.entry(TOOLS_ANSWER_ENV.to_owned()).or_insert_with(|| answer.clone());
    }
    env
}

#[cfg(test)]
#[path = "cmux_tools_answer_tests.rs"]
mod tests;
