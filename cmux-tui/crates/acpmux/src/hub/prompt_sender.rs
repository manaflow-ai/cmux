//! Who sent a prompt, as the agent gets it (`_meta.acpmux.sender`): another
//! agent's name, class and thread, so an agent that is itself a relay (`cmux
//! chief acp`) can pass them on and treat the words as that agent's, not as
//! the owner's. A person's prompt carries none. The agent's blocks are
//! unchanged; harnesses that do not know the key ignore it.

use serde_json::{Map, Value, json};

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
    let Some(name) = agent.filter(|n| !n.is_empty()) else { return params };
    let mut sender = Map::new();
    sender.insert("name".into(), json!(name));
    if let Some(class) = class {
        sender.insert("class".into(), json!(class));
    }
    if let Some(thread) = provenance.and_then(|p| p.get("threadId")).and_then(Value::as_str) {
        sender.insert("threadId".into(), json!(thread));
    }
    params["_meta"] = json!({"acpmux": {"sender": Value::Object(sender)}});
    params
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
    fn a_persons_prompt_names_no_sender() {
        let params = prompt_params("s", json!([{"type": "text", "text": "hi"}]), None, None, None);
        assert_eq!(params, json!({"sessionId": "s", "prompt": [{"type": "text", "text": "hi"}]}));
    }
}
