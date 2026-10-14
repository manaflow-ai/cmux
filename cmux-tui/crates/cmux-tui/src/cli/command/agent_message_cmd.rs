//! `agent message …`: a message to an agent (agent_message.rs sends and
//! delivers it), or `agent message release <message-id> --recipient <agent>
//! --approve|--decline`, the person's decision on a held delivery (one
//! `agent.message.release`). `release` is a reserved word there: an acpmux
//! session named release is addressed as `acp:release`.

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value};

use super::{CommandPlan, Flags, Selectors, UsageError, request};

pub(super) fn parse(
    words: &[&str],
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    if let ["release", rest @ ..] = words {
        return release(rest, flags, argv);
    }
    let from = flags.take("from");
    let thread = flags.take("thread");
    let reply_to = flags.take("reply-to");
    Ok(CommandPlan::AgentMessage(Box::new(super::super::agent_message::parse_message(
        words, argv, from, thread, reply_to,
    )?)))
}

fn release(
    words: &[&str],
    flags: &mut Flags,
    argv: Option<Vec<String>>,
) -> Result<CommandPlan, UsageError> {
    let [message_id] = words else {
        return Err(UsageError::new(
            "agent message release takes one message id: \
             agent message release <message-id> --recipient <agent> --approve|--decline",
        ));
    };
    if argv.is_some_and(|argv| !argv.is_empty()) {
        return Err(UsageError::new("agent message release takes no text"));
    }
    let recipient = flags.take("recipient").ok_or_else(|| {
        UsageError::new("name the held delivery's agent: --recipient <term_... or acp:<session>>")
    })?;
    let decision = match (flags.boolean("approve"), flags.boolean("decline")) {
        (true, false) => "approve",
        (false, true) => "decline",
        _ => return Err(UsageError::new("give exactly one of --approve or --decline")),
    };
    let mut params = Map::new();
    params.insert("message_id".into(), Value::String((*message_id).to_owned()));
    params.insert("recipient".into(), Value::String(recipient));
    params.insert("decision".into(), Value::String(decision.to_owned()));
    request(ResourceOperation::AgentMessageRelease, &Selectors::default(), flags, params)
}
