//! `conversation list|get|history|search|send|events`: the local
//! conversation owner (Home and the Chief) on `cmux.protocol/2`, one verb per
//! catalog operation. `cmux chief` is the chat on top of these.

use cmux_tui_core::resource::ResourceOperation as Op;
use serde_json::{Map, Value, json};

use super::{
    CommandPlan, Flags, Selectors, UsageError, add_stream_id, insert_bounded_u32, request, usage,
};

pub(super) fn parse_conversation(
    words: &[&str],
    flags: &mut Flags,
) -> Result<CommandPlan, UsageError> {
    let mut params = Map::new();
    let operation = match words {
        ["list"] => Op::ConversationList,
        ["search", query @ ..] if !query.is_empty() => {
            params.insert("query".into(), Value::String(query.join(" ")));
            if let Some(limit) = flags.take("limit") {
                insert_bounded_u32(&mut params, "limit", "--limit", limit, 1, 100)?;
            }
            Op::ConversationSearch
        }
        [conversation, action] => {
            params.insert("conversation".into(), Value::String(conversation_id(conversation)?));
            match *action {
                "get" | "show" => {
                    tail(flags, &mut params)?;
                    Op::ConversationGet
                }
                "history" => {
                    let before = flags.required("before-seq")?;
                    insert_bounded_u32(
                        &mut params,
                        "before_seq",
                        "--before-seq",
                        before,
                        1,
                        u32::MAX,
                    )?;
                    let limit = flags.required("limit")?;
                    insert_bounded_u32(&mut params, "limit", "--limit", limit, 1, 500)?;
                    Op::ConversationHistory
                }
                "send" => {
                    send(flags, &mut params)?;
                    Op::ConversationSend
                }
                "events" => {
                    tail(flags, &mut params)?;
                    if let Some(revision) = flags.take("cursor-rev") {
                        if revision.is_empty() || !revision.bytes().all(|b| b.is_ascii_digit()) {
                            return Err(UsageError::new("--cursor-rev takes a conversation rev"));
                        }
                        let generation = params["conversation"].clone();
                        params.insert(
                            "cursor".into(),
                            json!({"generation": generation, "revision": revision}),
                        );
                    }
                    add_stream_id(&mut params, flags)?;
                    Op::ConversationEvents
                }
                _ => return usage("conversation action"),
            }
        }
        _ => return usage("conversation action"),
    };
    request(operation, &Selectors::default(), flags, params)
}

/// A conversation id as the owner makes it: `conv_` then base-32 characters.
fn conversation_id(value: &str) -> Result<String, UsageError> {
    let ok = value.strip_prefix("conv_").is_some_and(|rest| {
        !rest.is_empty() && rest.len() <= 59 && rest.bytes().all(|b| b.is_ascii_alphanumeric())
    });
    if ok {
        Ok(value.to_owned())
    } else {
        Err(UsageError::new(format!("{value:?} is not a conversation id (conv_…)")))
    }
}

fn tail(flags: &mut Flags, params: &mut Map<String, Value>) -> Result<(), UsageError> {
    if let Some(tail) = flags.take("tail") {
        insert_bounded_u32(params, "tail", "--tail", tail, 0, 500)?;
    }
    Ok(())
}

fn send(flags: &mut Flags, params: &mut Map<String, Value>) -> Result<(), UsageError> {
    match (flags.take("text"), flags.take("parts-json")) {
        (Some(text), None) if !text.is_empty() => {
            params.insert("text".into(), Value::String(text));
        }
        (None, Some(parts)) => {
            let parts: Value = serde_json::from_str(&parts)
                .map_err(|error| UsageError::new(format!("--parts-json is not JSON: {error}")))?;
            if !parts.as_array().is_some_and(|items| (1..=16).contains(&items.len())) {
                return Err(UsageError::new("--parts-json takes an array of 1 to 16 parts"));
            }
            params.insert("parts".into(), parts);
        }
        _ => return Err(UsageError::new("give exactly one of --text and --parts-json")),
    }
    match (flags.take("reply-to"), flags.take("reply-part")) {
        (Some(message), part) => {
            let part_index = part.as_deref().unwrap_or("0").parse::<u32>().map_err(|_| {
                UsageError::new("--reply-part takes the part index (0 for the first part)")
            })?;
            params.insert(
                "reply_to".into(),
                json!({"message_id": message, "part_index": part_index}),
            );
        }
        (None, Some(_)) => return Err(UsageError::new("--reply-part needs --reply-to")),
        (None, None) => {}
    }
    Ok(())
}
