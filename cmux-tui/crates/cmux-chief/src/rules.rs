//! Pure rules of the brain host: the wake rule (home.md section 5), the
//! supervisor's prompt texts and status mapping, and reply keys. Port of
//! `mux/host/src/wake.ts` and `supervisor.ts`; the texts are the same bytes.

use cmux_conversation::{Message, Part, ParticipantKind, Summary, WorkStatus};

use crate::acp::{SessionStatus, SessionSummary, js_trim, utf16_prefix};

/// The Mac user's participant id.
pub const USER_LOCAL: &str = "user_local";
/// The Chief's participant id (wire id kept from phase A, decision D3).
pub const AGENT_MUX: &str = "agent_mux";
/// The Chief's acpmux session name.
pub const MUX_SESSION_NAME: &str = "mux";
/// The default conversation's create key.
pub const DEFAULT_CONVERSATION_KEY: &str = "mux-home-default";
/// Tag on every agent the Chief started; its value is the Chief's session name.
pub const PARENT_TAG: &str = "mux.parent";
/// Prefix of host prompts about child agents.
pub const EVENT_PREFIX: &str = "[mux-event]";
/// The owner's minimum gap between agent messages (2 s) plus a margin.
pub const AGENT_GAP_RETRY_MS: u64 = 2_200;
/// Extra delay before the one-shot outbox timer fires after the gap.
pub const AGENT_GAP_TIMER_SLACK_MS: u64 = 50;
/// Messages per catch-up page (the owner's maximum).
pub const PAGE: u32 = 500;

const EXCERPT: usize = 600;

/// Whether a message wakes the Chief: it participates and either the
/// conversation has one human and one agent, or it is a DM with the Chief,
/// or the message mentions the Chief or replies to one of its messages.
pub fn wakes(summary: &Summary, message: &Message, is_mux_message: impl Fn(&str) -> bool) -> bool {
    let Some(author) = summary.participants.iter().find(|p| p.id == message.author) else {
        return false;
    };
    if author.kind != ParticipantKind::Human || message.author == AGENT_MUX {
        return false;
    }
    let retracted = message.retracted_at.as_deref().is_some_and(|at| !at.is_empty());
    if !summary.participants.iter().any(|p| p.id == AGENT_MUX) || retracted {
        return false;
    }
    let count = |kind| summary.participants.iter().filter(|p| p.kind == kind).count();
    if count(ParticipantKind::Human) == 1 && count(ParticipantKind::Agent) == 1 {
        return true;
    }
    if summary.id.starts_with("conv_dm_") && summary.participants.len() == 2 {
        return true;
    }
    let mentioned = message.parts.iter().any(|part| match part {
        Part::Text { runs: Some(runs), .. } => {
            runs.iter().any(|run| run.mention.as_deref() == Some(AGENT_MUX))
        }
        _ => false,
    });
    mentioned || message.reply_to.as_ref().is_some_and(|r| is_mux_message(&r.message_id))
}

/// The plain text of a message (text parts joined by newlines).
pub fn message_text(message: &Message) -> String {
    message
        .parts
        .iter()
        .filter_map(|part| match part {
            Part::Text { text, .. } if !text.is_empty() => Some(text.as_str()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The prompt for a human message.
pub fn inbox_prompt(summary: &Summary, message: &Message) -> String {
    let author = summary
        .participants
        .iter()
        .find(|p| p.id == message.author)
        .map_or(message.author.as_str(), |p| p.display_name.as_str());
    format!("[conversation {} from {author}] {}", summary.id, message_text(message))
}

/// The reply key (idempotency key and client_msg_id) of a Chief turn.
pub fn turn_key(session_id: &str, turn_seq: u64) -> String {
    format!("turn:{session_id}:{turn_seq}")
}

/// Trimmed text (JavaScript trim) cut to `limit` UTF-16 units with an
/// ellipsis, never splitting a surrogate pair.
pub fn excerpt(text: &str, limit: usize) -> String {
    let flat = js_trim(text);
    if flat.encode_utf16().count() <= limit {
        return flat.to_owned();
    }
    format!("{}…", utf16_prefix(flat, limit - 1))
}

pub fn child_finished_prompt(child: &SessionSummary, reply: &str) -> String {
    let reply = excerpt(reply, EXCERPT);
    let reply = if reply.is_empty() { "(no reply text)".to_owned() } else { reply };
    format!(
        "{EVENT_PREFIX} child {} finished: {reply}\n({}, {}; full reply: `acpmux last {}`.) Tell the user what matters, briefly, and take the next step yourself if there is one.",
        child.name, child.harness, child.cwd, child.name
    )
}

/// The prompt for a child's permission request. Only string fields count (a
/// missing optionId prints as ""; name, else kind, else ""); rawInput is
/// canonical JSON (serde_json sorts object keys), cut to 600 UTF-16 units.
pub fn child_permission_prompt(child: &SessionSummary, request: &serde_json::Value) -> String {
    let tool_call = request.get("toolCall");
    let title = tool_call
        .and_then(|call| call.get("title"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("a tool call");
    let input = match tool_call.and_then(|call| call.get("rawInput")) {
        Some(raw) => format!("\nInput: {}", utf16_prefix(&raw.to_string(), EXCERPT)),
        None => String::new(),
    };
    let options: Vec<String> = request
        .get("options")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .map(|option| {
            let text = |key| option.get(key).and_then(serde_json::Value::as_str);
            let label = text("name").or_else(|| text("kind")).unwrap_or("");
            format!("{} ({label})", text("optionId").unwrap_or(""))
        })
        .collect();
    let options = if options.is_empty() { "(none)".to_owned() } else { options.join(", ") };
    format!(
        "{EVENT_PREFIX} child {} asks permission: {title}{input}\nOptions: {options}\nAnswer with `mux agents allow {} OPTION_ID` or `mux agents deny {}`. Ask the user first if it is destructive or outward-facing.",
        child.name, child.name, child.name
    )
}

/// The work card status for an acpmux session status.
pub fn work_status(status: SessionStatus) -> WorkStatus {
    match status {
        SessionStatus::Running => WorkStatus::Running,
        SessionStatus::Waiting => WorkStatus::Waiting,
        SessionStatus::Disconnected | SessionStatus::Closed => WorkStatus::Failed,
        SessionStatus::Idle | SessionStatus::Ready => WorkStatus::Done,
    }
}

/// A child turn ended: it left `running` for `ready` or `idle`.
pub fn turn_ended(before: Option<SessionStatus>, after: SessionStatus) -> bool {
    before == Some(SessionStatus::Running)
        && matches!(after, SessionStatus::Ready | SessionStatus::Idle)
}

/// A work part for a child session.
pub fn work_part(session: &str, status: WorkStatus, preview: Option<&str>) -> Part {
    Part::Work {
        session: session.to_owned(),
        host: None,
        status,
        preview: preview.filter(|p| !p.is_empty()).map(|p| excerpt(p, 200)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_conversation::{PartRef, Participant, TextRun};
    use std::collections::BTreeMap;

    fn person(id: &str, kind: ParticipantKind) -> Participant {
        Participant {
            id: id.into(),
            kind,
            display_name: id.into(),
            agent_class: None,
            acp_session: None,
        }
    }

    fn summary(id: &str, participants: Vec<Participant>) -> Summary {
        Summary {
            id: id.into(),
            owner: "local".into(),
            title: "t".into(),
            participants,
            last_seq: 0,
            rev: 0,
            created_at: String::new(),
            updated_at: String::new(),
            last_message: None,
            read_cursors: BTreeMap::new(),
        }
    }

    fn message(author: &str, runs: Option<Vec<TextRun>>, reply_to: Option<&str>) -> Message {
        Message {
            id: "msg_x".into(),
            conversation: "c".into(),
            seq: 1,
            client_msg_id: "k".into(),
            author: author.into(),
            parts: vec![Part::Text { text: "hi".into(), runs }],
            reply_to: reply_to.map(|id| PartRef { message_id: id.into(), part_index: 0 }),
            created_at: String::new(),
            edited_at: None,
            retracted_at: None,
            reactions: Vec::new(),
        }
    }

    #[test]
    fn the_wake_rule() {
        let human = ParticipantKind::Human;
        let agent = ParticipantKind::Agent;
        let one_to_one =
            summary("conv_a", vec![person(USER_LOCAL, human), person(AGENT_MUX, agent)]);
        assert!(wakes(&one_to_one, &message(USER_LOCAL, None, None), |_| false));
        assert!(!wakes(&one_to_one, &message(AGENT_MUX, None, None), |_| false));
        let group = summary(
            "conv_b",
            vec![person(USER_LOCAL, human), person("user_2", human), person(AGENT_MUX, agent)],
        );
        assert!(!wakes(&group, &message(USER_LOCAL, None, None), |_| false));
        let mention = TextRun { start: 0, length: 2, mention: Some(AGENT_MUX.into()), link: None };
        assert!(wakes(&group, &message(USER_LOCAL, Some(vec![mention]), None), |_| false));
        assert!(wakes(&group, &message(USER_LOCAL, None, Some("msg_m")), |id| id == "msg_m"));
        let mut retracted = message(USER_LOCAL, None, None);
        retracted.retracted_at = Some("t".into());
        assert!(!wakes(&one_to_one, &retracted, |_| false));
        let without = summary("conv_c", vec![person(USER_LOCAL, human), person("agent_x", agent)]);
        assert!(!wakes(&without, &message(USER_LOCAL, None, None), |_| false));
    }

    #[test]
    fn excerpt_cuts_with_an_ellipsis() {
        assert_eq!(excerpt("  short ", 10), "short");
        assert_eq!(excerpt("abcdefghij", 5), "abcd…");
    }
}
