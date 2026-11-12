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
mod tests {
    use super::*;

    #[test]
    fn an_agent_message_names_its_sender_class_and_thread() {
        let provenance = json!({"kind": "agent_message", "threadId": "t1"});
        let params =
            prompt_params("s", json!([]), Some("lane-a"), Some("question"), Some(&provenance));
        assert_eq!(
            params["_meta"]["acpmux"]["sender"],
            json!({"name": "lane-a", "class": "question", "threadId": "t1"})
        );
        assert_eq!(params["sessionId"], "s");
    }

    #[test]
    fn a_steer_keeps_its_own_meta_and_names_its_sender() {
        let mut params = json!({"sessionId": "s", "prompt": [], "_meta": {"steer": true}});
        add_sender(&mut params, Some("lane-a"), None, None);
        assert_eq!(
            params["_meta"],
            json!({"steer": true, "acpmux": {"sender": {"name": "lane-a"}}})
        );
    }

    #[test]
    fn a_chiefs_message_names_its_chief() {
        // A Chief's turn session sent it (`prompt_provenance::stamp_chief`):
        // the relay of another Chief (`cmux chief acp`) routes its reply
        // back into that Chief's chat by this id.
        let provenance = json!({"kind": "session_message", "from": "s-turn",
            "fromName": "Codex Chief", "fromChief": "agent_codex", "threadId": "t2"});
        let params =
            prompt_params("s", json!([]), Some("Codex Chief"), Some("question"), Some(&provenance));
        assert_eq!(
            params["_meta"]["acpmux"]["sender"],
            json!({"name": "Codex Chief", "sessionId": "s-turn", "class": "question", "threadId": "t2",
                   "chief": "agent_codex"})
        );
    }

    #[test]
    fn the_agent_learns_who_the_daemon_knows_sent_it_apart_from_its_name() {
        let session = crate::prompt_provenance::session_message("s-a", "lane-a", "s-b");
        let session = crate::prompt_provenance::observed(session, "unix");
        let params = prompt_params("s", json!([]), Some("lane-a"), None, Some(&session));
        assert_eq!(
            params["_meta"]["acpmux"]["sender"],
            json!({"name": "lane-a", "verified": true, "transport": "unix", "sessionId": "s-a"})
        );
        let named = crate::prompt_provenance::observed(
            crate::prompt_provenance::named_sender("codex@box", "s-b"),
            "unix",
        );
        let params = prompt_params("s", json!([]), Some("codex@box"), None, Some(&named));
        assert_eq!(params["_meta"]["acpmux"]["sender"]["verified"], false);
        // A prompt no proof attributes says so, with no name: never the owner's.
        let unknown = crate::prompt_provenance::unverified("s-b", "unix", Map::new());
        let params = prompt_params("s", json!([]), None, None, Some(&unknown));
        assert_eq!(
            params["_meta"]["acpmux"]["sender"],
            json!({"verified": false, "transport": "unix"})
        );
        // The program the daemon saw send it goes along (`sender_program.rs`).
        let mut seen = unknown.clone();
        seen["program"] = json!({"name": "next-autoland"});
        let params = prompt_params("s", json!([]), None, None, Some(&seen));
        assert_eq!(
            params["_meta"]["acpmux"]["sender"]["program"],
            json!({"name": "next-autoland"})
        );
    }

    #[test]
    fn an_edited_agent_message_still_names_its_sender_to_the_agent() {
        let provenance = json!({
            "kind": "agent_message",
            "from": "lane-a",
            "editedBy": {"actor": "owner"},
        });
        let params = prompt_params("s", json!([]), None, None, Some(&provenance));
        assert_eq!(
            params["_meta"]["acpmux"]["sender"],
            json!({"name": "lane-a", "editedBy": {"actor": "owner"}})
        );
    }

    #[test]
    fn a_fan_in_turn_routes_its_sender_by_its_heads_chief_and_thread() {
        // A fan-in turn marks its blocks by its digest (`turns.rs`), but a relay
        // (`cmux chief acp`) still routes the reply by the head message's Chief and thread.
        let head = json!({"kind": "session_message", "from": "s-turn",
            "fromName": "Codex Chief", "fromChief": "agent_codex", "threadId": "t2"});
        let digest = json!({"kind": "agent_digest", "messages": [head.clone()]});
        let params = turn_params(
            "s",
            json!([{"type": "text", "text": "hi"}]),
            Some("Codex Chief"),
            Some("question"),
            Some(&head),
            Some(&digest),
        );
        let sender = &params["_meta"]["acpmux"]["sender"];
        assert_eq!(sender["chief"], "agent_codex");
        assert_eq!(sender["threadId"], "t2");
        assert_eq!(sender["sessionId"], "s-turn");
    }

    #[test]
    fn a_persons_prompt_names_no_sender() {
        let params = prompt_params("s", json!([{"type": "text", "text": "hi"}]), None, None, None);
        assert_eq!(params, json!({"sessionId": "s", "prompt": [{"type": "text", "text": "hi"}]}));
    }
}
