//! Who sent a prompt, as the agent gets it (`_meta.acpmux.sender`): another
//! agent's name, class and thread, and who the daemon knows sent it apart from
//! what it claimed (`verified`, `transport`, `sessionId`, `harness`, `editedBy`,
//! `forwardedBy`, `prompt_provenance.rs`), so an agent that is itself a relay
//! (`cmux chief acp`) can pass on the original sender beside itself and treat
//! the words as that sender's, never the owner's. An `unverified` prompt says
//! so with no name. A person's prompt carries none. The agent's blocks are
//! unchanged; harnesses that do not know the key ignore it.

use serde_json::{Map, Value, json};

/// [`add_sender`] for a steer's class and provenance.
pub(super) fn add_steer_sender(
    params: &mut Value,
    sender: Option<&str>,
    class: Option<crate::prompt_class::PromptClass>,
    provenance: Option<&Value>,
) {
    add_sender(params, sender, class.map(crate::prompt_class::PromptClass::as_str), provenance);
}

/// The `session/prompt` params for queued prompt `run`: its blocks marked under its turn's
/// effective `provenance` (a fan-in turn's is its digest's, `turns.rs`), its sender routed by
/// `run`'s own (the digest has no `threadId`, `fromChief` or origin of its head's).
pub(super) fn run_params(
    agent_sid: &str,
    prompt: Value,
    run: &super::queue::PromptRun,
    provenance: Option<&Value>,
) -> Value {
    let class = run.class.map(crate::prompt_class::PromptClass::as_str);
    turn_params(agent_sid, prompt, run.agent.as_deref(), class, run.provenance.as_ref(), provenance)
}

/// [`run_params`] apart from the run: marks by `effective`, sender by `own`.
fn turn_params(
    agent_sid: &str,
    prompt: Value,
    agent: Option<&str>,
    class: Option<&str>,
    own: Option<&Value>,
    effective: Option<&Value>,
) -> Value {
    let mut params = json!({"sessionId": agent_sid, "prompt": prompt});
    super::prompt_attribution::mark(&mut params, agent, effective);
    sender_meta(&mut params, agent, class, own);
    params
}

/// The `session/prompt` params for `prompt` to `agent_sid`, with the sender of
/// an agent's message (`agent`, its `class` and its provenance's `threadId`).
#[cfg(test)]
fn prompt_params(
    agent_sid: &str,
    prompt: Value,
    agent: Option<&str>,
    class: Option<&str>,
    provenance: Option<&Value>,
) -> Value {
    let mut params = json!({"sessionId": agent_sid, "prompt": prompt});
    add_sender(&mut params, agent, class, provenance);
    params
}

/// Adds `_meta.acpmux.sender` to `params` (a turn's prompt or a steer) when
/// `agent` sent it, and the marks of who wrote it to its blocks.
pub(super) fn add_sender(
    params: &mut Value,
    agent: Option<&str>,
    class: Option<&str>,
    provenance: Option<&Value>,
) {
    // The agent reads who wrote it in the prompt too (`prompt_attribution.rs`).
    super::prompt_attribution::mark(params, agent, provenance);
    sender_meta(params, agent, class, provenance);
}

/// Adds `_meta.acpmux.sender` to `params` when `agent` sent it (or it is `unverified`).
fn sender_meta(
    params: &mut Value,
    agent: Option<&str>,
    class: Option<&str>,
    provenance: Option<&Value>,
) {
    // A message the person edited is theirs to act on (`queue_edit.rs`), but the agent still
    // learns who first sent it, beside its `editedBy`.
    let edited = provenance.is_some_and(|p| p.get(crate::prompt_provenance::EDITED_BY).is_some());
    let named = edited.then(|| super::digest::named_sender(provenance)).flatten();
    let name = agent.filter(|n| !n.is_empty()).or(named.as_deref());
    let unverified = provenance.and_then(|p| p.get("kind")).and_then(Value::as_str)
        == Some(crate::prompt_provenance::UNVERIFIED_KIND);
    if name.is_none() && !unverified {
        return;
    }
    let mut sender = Map::new();
    if let Some(name) = name {
        sender.insert("name".into(), json!(name));
    }
    origin_fields(&mut sender, provenance);
    if let Some(class) = class {
        sender.insert("class".into(), json!(class));
    }
    if let Some(thread) = provenance.and_then(|p| p.get("threadId")).and_then(Value::as_str) {
        sender.insert("threadId".into(), json!(thread));
    }
    // A Chief's turn sent it (`prompt_provenance::stamp_chief`): that Chief's
    // participant id, so a relay to another Chief (`cmux chief acp`) can send
    // the reply back into the sender's chat.
    let chief = provenance.and_then(|p| p.get(crate::prompt_provenance::FROM_CHIEF));
    if let Some(chief) = chief.and_then(Value::as_str) {
        sender.insert("chief".into(), json!(chief));
    }
    // Params are always an object here (`prompt_params`, a steer's); anything
    // else is left as it is.
    let Some(fields) = params.as_object_mut() else { return };
    let meta = fields.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    if let Some(meta) = meta.as_object_mut() {
        meta.insert("acpmux".into(), json!({"sender": Value::Object(sender)}));
    }
}

/// Who the daemon knows sent it, apart from its name: copied from the provenance as the daemon
/// stamped it, never from the prompt's own text.
fn origin_fields(sender: &mut Map<String, Value>, provenance: Option<&Value>) {
    let Some(p) = provenance.and_then(Value::as_object) else { return };
    use crate::prompt_provenance as pp;
    if let Some(verified) = p.get(pp::VERIFIED).and_then(Value::as_bool) {
        sender.insert("verified".into(), json!(verified));
    }
    for (from, to) in [
        (pp::TRANSPORT, "transport"),
        (pp::FROM_SESSION_ID, "sessionId"),
        (pp::FROM_HARNESS, "harness"),
    ] {
        if let Some(value) = p.get(from).and_then(Value::as_str) {
            sender.insert(to.into(), json!(value));
        }
    }
    // A session's message names its session as `from` (`session_message`).
    if !sender.contains_key("sessionId")
        && p.get("kind").and_then(Value::as_str) == Some("session_message")
        && let Some(from) = p.get("from").and_then(Value::as_str)
    {
        sender.insert("sessionId".into(), json!(from));
    }
    for key in [pp::EDITED_BY, pp::FORWARDED_BY, pp::CLAIMED, crate::sender_program::PROVENANCE_KEY]
    {
        if let Some(value) = p.get(key) {
            sender.insert(key.into(), value.clone());
        }
    }
}

#[cfg(test)]
mod tests;
