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
/// The default conversation's create key: the app's Home Chief conversation
/// (HomeChiefName.createKey), so the user has one Chief conversation. Before:
/// "mux-home-default" (a host.json that names it switches once, at the next
/// daemon connect).
pub const DEFAULT_CONVERSATION_KEY: &str = "home-chief";
/// The Home Chief conversation's title and the Chief participant's name (the
/// app's HomeChiefName).
pub const CHIEF_CONVERSATION_TITLE: &str = "Chief";
pub const CHIEF_DISPLAY_NAME: &str = "Chief";
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

/// The participant id prefix of a paired install (the relay's remote participant).
pub const REMOTE_PREFIX: &str = "remote_";

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
    // The remote-origin gate (server-remote-conversations.md section 6; the
    // TypeScript rules.wakes). Default deny: a device message passes only
    // when the owner stamped it as relayed from exactly this author
    // (`origin.install`, author `remote_<install>`) and the author is the
    // owner's own paired device (a human whose person is user_local).
    let remote = message.origin.is_some()
        || author.person.is_some()
        || message.author.starts_with(REMOTE_PREFIX);
    if remote {
        let Some(cmux_conversation::Origin::Remote { install }) = &message.origin else {
            return false;
        };
        if install.is_empty()
            || message.author != format!("{REMOTE_PREFIX}{install}")
            || author.person.as_deref() != Some(USER_LOCAL)
        {
            return false;
        }
    }
    let retracted = message.retracted_at.as_deref().is_some_and(|at| !at.is_empty());
    if !summary.participants.iter().any(|p| p.id == AGENT_MUX) || retracted {
        return false;
    }
    // Count persons, not participant ids: a paired device (`person`) is the
    // same human as its person, so pairing does not change the rule
    // (decision D-C).
    let mut persons: Vec<&str> = summary
        .participants
        .iter()
        .filter(|p| p.kind == ParticipantKind::Human)
        .map(|p| p.person.as_deref().unwrap_or(&p.id))
        .collect();
    persons.sort_unstable();
    persons.dedup();
    let agents = summary.participants.iter().filter(|p| p.kind == ParticipantKind::Agent).count();
    if persons.len() == 1 && agents == 1 {
        return true;
    }
    if summary.id.starts_with("conv_dm_") && persons.len() + agents == 2 {
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

/// The reply key (idempotency key and client_msg_id) of a Chief turn:
/// `turn:<session>:<turn seq>`, or `turn:<session>:<epoch>:<turn seq>` after
/// a cursor_reset (a re-imported log reuses seqs).
pub fn turn_key(session_id: &str, turn_seq: u64, epoch: Option<u64>) -> String {
    match epoch {
        Some(epoch) => format!("turn:{session_id}:{epoch}:{turn_seq}"),
        None => format!("turn:{session_id}:{turn_seq}"),
    }
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

/// A child turn ended: it left `running` or `waiting` (a permission,
/// answered or denied) for `ready` or `idle`.
pub fn turn_ended(before: Option<SessionStatus>, after: SessionStatus) -> bool {
    matches!(before, Some(SessionStatus::Running | SessionStatus::Waiting))
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
            person: None,
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
            origin: None,
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

    /// Pairing adds a device of the same person: a plain local message still
    /// wakes the Chief; a device message wakes it only when the owner stamped
    /// it as relayed from that device (the remote-origin gate).
    #[test]
    fn a_paired_device_does_not_change_the_wake_rule() {
        let human = ParticipantKind::Human;
        let mut device = person("remote_inst_1", human);
        device.person = Some(USER_LOCAL.into());
        let paired = summary(
            "conv_a",
            vec![person(USER_LOCAL, human), person(AGENT_MUX, ParticipantKind::Agent), device],
        );
        assert!(wakes(&paired, &message(USER_LOCAL, None, None), |_| false));
        assert!(!wakes(&paired, &message("remote_inst_1", None, None), |_| false));
        let mut remote = message(USER_LOCAL, None, None);
        remote.origin = Some(cmux_conversation::Origin::Remote { install: "inst_1".into() });
        assert!(!wakes(&paired, &remote, |_| false), "stamped for another author");
        let mut relayed = message("remote_inst_1", None, None);
        relayed.origin = Some(cmux_conversation::Origin::Remote { install: "inst_1".into() });
        assert!(wakes(&paired, &relayed, |_| false), "the owner's device, relayed");
    }

    /// Float gap (plans/cmux-next/chief-mac.md section 4): the cores write
    /// floats differently, so no code compares this text between them and
    /// the corpus has no floats in rawInput. This pins the Rust text; the
    /// TypeScript test (mux/packages/brain/tests/rules.test.ts) pins
    /// `{"a":2,"x":1}`.
    #[test]
    fn raw_input_float_text_is_serde_json() {
        let child: SessionSummary = serde_json::from_value(serde_json::json!({
            "sessionId": "s_w", "name": "writer", "status": "waiting"
        }))
        .unwrap();
        let request: serde_json::Value =
            serde_json::from_str(r#"{"toolCall":{"title":"t","rawInput":{"x":1.0,"a":2}}}"#)
                .unwrap();
        assert!(
            child_permission_prompt(&child, &request).contains("\nInput: {\"a\":2,\"x\":1.0}\n")
        );
    }

    #[test]
    fn excerpt_cuts_with_an_ellipsis() {
        assert_eq!(excerpt("  short ", 10), "short");
        assert_eq!(excerpt("abcdefghij", 5), "abcd…");
    }
}
