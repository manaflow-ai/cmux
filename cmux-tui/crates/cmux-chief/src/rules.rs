//! Pure rules of the brain host: the wake rule (home.md section 5), the
//! supervisor's prompt texts and status mapping, and reply keys. Port of
//! `mux/host/src/wake.ts` and `supervisor.ts`; the texts are the same bytes.

use cmux_conversation::{AgentClass, Message, Part, ParticipantKind, Summary, WorkStatus};

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
/// acpmux's names for a session in a person's approval card (its
/// `hub/permissions/display.rs`): who asks (`mux.label` on the asker), and
/// whom a message reaches (`mux.handle` and `mux.label` on a child, found
/// among the sessions whose `mux.parent` is the asker's `mux.children`).
pub const LABEL_TAG: &str = "mux.label";
pub const HANDLE_TAG: &str = "mux.handle";
pub const CHILDREN_TAG: &str = "mux.children";
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

/// Which messages of a group conversation wake a Chief.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum GroupWake {
    /// Only a mention of the Chief or a reply to one of its messages (the
    /// default, home.md section 5).
    #[default]
    Mention,
    /// Every person's message: the Chief reads the whole conversation and
    /// decides itself whether to act (a Chief that acts on its own).
    Every,
}

/// Whether a message wakes the Chief: it participates and either the
/// conversation has one human and one agent, or it is a DM with the Chief,
/// or the message mentions the Chief or replies to one of its messages.
pub fn wakes(summary: &Summary, message: &Message, is_mux_message: impl Fn(&str) -> bool) -> bool {
    let rule = WakeRule { chief: AGENT_MUX, group: GroupWake::Mention, chiefs: false };
    wakes_as(&rule, summary, message, is_mux_message)
}

/// Which messages wake one Chief.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WakeRule<'a> {
    /// The Chief's participant id (one of several Chiefs on one owner).
    pub chief: &'a str,
    /// The group rule.
    pub group: GroupWake,
    /// Whether another Chief's message (an agent with `agent_class` mux)
    /// wakes it as a person's does. The owner's per-thread budget
    /// (`cmux_conversation::MAX_AGENT_TURNS`) bounds Chief-to-Chief talk; the
    /// caller may pre-check it with `cmux_conversation::thread_agent_streak`.
    pub chiefs: bool,
}

/// Whether `id` is a Chief of `summary` (an agent of class mux).
pub fn is_chief(summary: &Summary, id: &str) -> bool {
    summary.participants.iter().any(|p| {
        p.id == id && p.kind == ParticipantKind::Agent && p.agent_class == Some(AgentClass::Mux)
    })
}

/// Whether `message` was written by this Chief owner's own local identity or
/// one of that person's paired devices. Other human participants may wake a
/// Chief, but they cannot authorize effects on the owner's machine.
pub fn is_owner_message(summary: &Summary, message: &Message) -> bool {
    is_owner_message_as(summary, message, USER_LOCAL)
}

/// [`is_owner_message`] for an explicit owner participant id (a placed Cloud
/// brain uses its `user_...` owner rather than the local `user_local`).
pub fn is_owner_message_as(summary: &Summary, message: &Message, owner: &str) -> bool {
    summary.participants.iter().any(|p| {
        p.id == message.author
            && p.kind == ParticipantKind::Human
            && (p.id == owner || p.person.as_deref() == Some(owner))
    })
}

/// [`wakes`] for the Chief `rule.chief` with the group rule `rule.group`. A
/// Chief never wakes on its own message. Other agents never wake it; other
/// Chiefs do only with `rule.chiefs`.
pub fn wakes_as(
    rule: &WakeRule<'_>,
    summary: &Summary,
    message: &Message,
    is_mux_message: impl Fn(&str) -> bool,
) -> bool {
    let chief = rule.chief;
    let group = rule.group;
    let Some(author) = summary.participants.iter().find(|p| p.id == message.author) else {
        return false;
    };
    if message.author == chief {
        return false;
    }
    let by_chief = rule.chiefs && is_chief(summary, &message.author);
    if author.kind != ParticipantKind::Human && !by_chief {
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
    if !summary.participants.iter().any(|p| p.id == chief) || retracted {
        return false;
    }
    if group == GroupWake::Every {
        return true;
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
            runs.iter().any(|run| run.mention.as_deref() == Some(chief))
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
