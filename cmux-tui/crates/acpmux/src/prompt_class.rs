//! A message's class (`_meta.acpmux.class` on `session/prompt`, `acpmux send --class`): what
//! another agent's message asks of the session it goes to.
//!
//! - `block`: the sender cannot go on until the receiver acts.
//! - `question`: the sender asks something and waits for the answer.
//! - `result`: the sender reports work it finished (a pull request, a verdict, a merge).
//! - `fyi`: information the receiver may read at its leisure.
//!
//! Only another agent's message has a class (`hub/digest.rs` `agent_sender`): one sent with
//! none counts as `result`, and so do a lane's report (`hub/lane_reports.rs`) and its task result
//! card (`hub/tasks.rs`). The person's own prompt has none, whatever it says. The class is stored
//! on the queued prompt (its `queued` record, so a restart keeps it) and shown in each queue row
//! as `class`; an edit (`_acpmux/queue_edit`) makes the prompt the person's, so it drops it.
//!
//! A coordinator session reads it to decide which messages wake it (block, question) and which
//! wait for its next turn's inbox digest (result, fyi).

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::rpc::RpcError;

/// What another agent's message asks of the session it goes to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum PromptClass {
    /// The sender cannot go on until the receiver acts.
    Block,
    /// The sender asks something and waits for the answer.
    Question,
    /// The sender reports work it finished. A message sent with no class is one.
    Result,
    /// Information to read at leisure.
    Fyi,
}

impl PromptClass {
    /// Every class, in the order a digest reads them.
    pub const ALL: [Self; 4] = [Self::Block, Self::Question, Self::Result, Self::Fyi];

    /// What `_meta.acpmux.class`, a `queued` record and a queue row say.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Block => "block",
            Self::Question => "question",
            Self::Result => "result",
            Self::Fyi => "fyi",
        }
    }

    /// The class `s` names, `None` for anything else. `blocker` is a block and `action` a result
    /// (the inbox's names, `hub/inbox.rs`).
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "blocker" => Some(Self::Block),
            "action" => Some(Self::Result),
            s => Self::ALL.into_iter().find(|c| c.as_str() == s),
        }
    }

    /// Whether a message of this class needs the receiver now: a block or a question.
    pub fn urgent(self) -> bool {
        matches!(self, Self::Block | Self::Question)
    }
}

impl std::fmt::Display for PromptClass {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The values `_meta.acpmux.class` takes, for a refusal and `--class`'s help.
pub const VALUES: &str = "block, question, result, fyi, blocker (a block) or action (a result)";

/// `_meta.acpmux.class` of a `session/prompt`: `None` when absent or null, refused
/// (`class.value_refused`) when it is not one of the four classes.
pub fn declared(params: &Value) -> Result<Option<PromptClass>, RpcError> {
    match params.pointer("/_meta/acpmux/class") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if PromptClass::parse(s).is_some() => Ok(PromptClass::parse(s)),
        Some(_) => Err(RpcError::invalid_params(format!("class must be one of {VALUES}"))
            .with_data(json!({"reason": "class.value_refused"}))),
    }
}

/// The class a prompt is stored with: another agent's message (`agent`) has the one it
/// declared, else `result`; the person's own prompt has none.
pub fn of_message(declared: Option<PromptClass>, agent: bool) -> Option<PromptClass> {
    agent.then(|| declared.unwrap_or(PromptClass::Result))
}

/// The class a `queued` record names, `None` when it names none (a record from before classes,
/// or the person's prompt).
pub fn recorded(msg: &Value) -> Option<PromptClass> {
    msg.get("class").and_then(Value::as_str).and_then(PromptClass::parse)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with(class: Value) -> Value {
        json!({"_meta": {"acpmux": {"class": class}}})
    }

    #[test]
    fn the_four_classes_are_accepted_and_nothing_else() {
        for class in PromptClass::ALL {
            assert_eq!(declared(&with(json!(class.as_str()))).unwrap(), Some(class));
            assert_eq!(serde_json::to_value(class).unwrap(), json!(class.as_str()));
        }
        assert_eq!(declared(&json!({})).unwrap(), None);
        assert_eq!(declared(&with(Value::Null)).unwrap(), None);
        for bad in [json!("Block"), json!("urgent"), json!(""), json!(" fyi"), json!(1)] {
            let err = declared(&with(bad.clone())).expect_err(&bad.to_string());
            assert_eq!(err.data.as_ref().unwrap()["reason"], "class.value_refused");
        }
    }

    #[test]
    fn an_agent_message_with_no_class_is_a_result_and_the_person_has_none() {
        assert_eq!(of_message(None, true), Some(PromptClass::Result));
        assert_eq!(of_message(Some(PromptClass::Block), true), Some(PromptClass::Block));
        assert_eq!(of_message(Some(PromptClass::Question), false), None);
        assert_eq!(of_message(None, false), None);
    }

    #[test]
    fn only_blocks_and_questions_are_urgent() {
        let urgent: Vec<_> = PromptClass::ALL.into_iter().filter(|c| c.urgent()).collect();
        assert_eq!(urgent, [PromptClass::Block, PromptClass::Question]);
        assert_eq!(recorded(&json!({"class": "fyi"})), Some(PromptClass::Fyi));
        assert_eq!(recorded(&json!({"class": "nope"})), None);
        assert_eq!(recorded(&json!({})), None);
    }

    #[test]
    fn a_queued_record_from_before_classes_restores_an_agents_message_as_a_result() {
        let old = json!({"promptId": "p", "fromAgent": "lane-a"});
        assert_eq!(of_message(recorded(&old), true), Some(PromptClass::Result));
        assert_eq!(of_message(recorded(&old), false), None);
    }
}
