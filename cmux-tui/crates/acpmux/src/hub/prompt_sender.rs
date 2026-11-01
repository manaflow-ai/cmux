//! Who sent a prompt, as the agent gets it (`_meta.acpmux.sender`): another
//! agent's name, class and thread, so an agent that is itself a relay (`cmux
//! chief acp`) can pass them on and treat the words as that agent's, not as
//! the owner's. A person's prompt carries none. The agent's blocks are
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

/// [`prompt_params`] for queued prompt `run`.
pub(super) fn run_params(agent_sid: &str, prompt: Value, run: &super::queue::PromptRun) -> Value {
    let class = run.class.map(crate::prompt_class::PromptClass::as_str);
    prompt_params(agent_sid, prompt, run.agent.as_deref(), class, run.provenance.as_ref())
}

/// The `session/prompt` params for `prompt` to `agent_sid`, with the sender of
/// an agent's message (`agent`, its `class` and its provenance's `threadId`).
pub(super) fn prompt_params(
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
/// `agent` sent it.
pub(super) fn add_sender(
    params: &mut Value,
    agent: Option<&str>,
    class: Option<&str>,
    provenance: Option<&Value>,
) {
    let Some(name) = agent.filter(|n| !n.is_empty()) else { return };
    let mut sender = Map::new();
    sender.insert("name".into(), json!(name));
    if let Some(class) = class {
        sender.insert("class".into(), json!(class));
    }
    if let Some(thread) = provenance.and_then(|p| p.get("threadId")).and_then(Value::as_str) {
        sender.insert("threadId".into(), json!(thread));
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
    fn a_persons_prompt_names_no_sender() {
        let params = prompt_params("s", json!([{"type": "text", "text": "hi"}]), None, None, None);
        assert_eq!(params, json!({"sessionId": "s", "prompt": [{"type": "text", "text": "hi"}]}));
    }
}
