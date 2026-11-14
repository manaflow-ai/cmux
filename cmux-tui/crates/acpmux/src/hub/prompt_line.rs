//! Part of `Hub`; see `hub/mod.rs`. The line a prompt leaves on its chat's summary
//! (`last_prompt`): the sidebar's `lastMessage` until the reply comes, a notification's body
//! (cmux-tui-core `agent_chat_notices.rs`) and Chief's views read it. Another agent's message
//! reads as its sender's name and the first line of its words ("coord-deputy: Merged #23727"),
//! never as the envelope its agent got ("[cmux agent message] from … Message id: … This
//! message was delivered by cmux …"). The pane draws the same prompts as that agent's message
//! (webviews `conversation/incomingMessage.ts`), which these rules follow.

use serde_json::Value;

/// The line `text` leaves on its chat's summary: "name: first line" for another agent's
/// message, else `text` itself.
pub(super) fn prompt_line(text: &str, client: &str, provenance: Option<&Value>) -> String {
    let Some((name, words)) = message(text, client, provenance) else {
        return text.to_owned();
    };
    match words.lines().map(str::trim).find(|l| !l.is_empty()) {
        Some(first) => format!("{name}: {first}"),
        None => name,
    }
}

/// Whether a prompt with `provenance` is acpmux's own notice of other agents' messages rather
/// than anyone's words: an inbox notice ("[inbox] New messages from other agents in 1 thread"),
/// an inbox digest or an agent digest. A History of what was asked (the sidebar hover card) leaves
/// such a turn out; one agent's message stays, as "name: words" (`prompt_line`).
pub(super) fn is_notice(provenance: Option<&Value>) -> bool {
    let kind = provenance.and_then(|p| p.get("kind")).and_then(Value::as_str);
    kind.is_some_and(|k| {
        [
            super::inbox::NOTICE_KIND,
            super::digest::DIGEST_KIND,
            super::digest::inbox_digest::KIND,
            super::touched::NOTICE_KIND,
        ]
        .contains(&k)
    })
}

/// The words of `text` a chat's title is made from (`titles.rs`): another agent's message
/// without its sender and envelope, else `text` itself. A turn of several messages has no words
/// of one sender: it stays as it is.
pub(super) fn prompt_words<'a>(
    text: &'a str,
    client: &str,
    provenance: Option<&Value>,
) -> std::borrow::Cow<'a, str> {
    let kind = provenance.and_then(|p| p.get("kind")).and_then(Value::as_str);
    let several = [super::digest::DIGEST_KIND, super::digest::inbox_digest::KIND];
    match message(text, client, provenance) {
        Some((_, words)) if !kind.is_some_and(|k| several.contains(&k)) => words.into(),
        _ => text.into(),
    }
}

/// Who sent `text` and its words, when it is another agent's message: its provenance says so,
/// or (with none) `acpmux send` at a shell put the sender's name in brackets before it, or
/// Claude Code's own envelope wraps it in an adopted chat.
fn message(text: &str, client: &str, provenance: Option<&Value>) -> Option<(String, String)> {
    let field = |key: &str| {
        provenance?.get(key)?.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    match provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) {
        // A tool's notice reads as its sender and its title, not the rendered `[notice from …]`
        // line its agent got (`prompt_provenance::notice_text`).
        Some(crate::prompt_provenance::NOTICE_KIND | super::touched::NOTICE_KIND) => {
            let name = field("fromName")?;
            let title = provenance?.pointer("/notice/title")?.as_str()?.trim().to_owned();
            Some((name, title))
        }
        Some("session_message" | "subsession_message") => {
            let name =
                field("fromShortName").or_else(|| field("fromName")).or_else(|| field("from"))?;
            Some((name, text.to_owned()))
        }
        Some("agent_message") => {
            let name = field("fromName").or_else(|| field("from"))?;
            let words = field("msgId").and_then(|id| rendered_body(text, &id)).unwrap_or(text);
            Some((name, words.to_owned()))
        }
        // `[NAME] verdict or first sentence` (`lane_reports.rs`); legacy report titles work too.
        Some(super::lane_reports::KIND) => name_prefixed(text),
        Some(super::digest::DIGEST_KIND) => {
            let messages = provenance?.get("messages")?.as_array()?;
            let name = senders(messages.iter().filter_map(|m| m.get("from")?.as_str()))?;
            Some((name, format!("{} messages", messages.len())))
        }
        // `[inbox digest] N messages …` (`inbox_digest.rs`): its senders, as a turn of them reads.
        Some(super::digest::inbox_digest::KIND) => {
            let parts = provenance?.get("parts")?.as_array()?;
            let name = senders(parts.iter().filter_map(|m| m.get("fromName")?.as_str()))?;
            Some((name, format!("inbox digest of {} messages", parts.len())))
        }
        Some(_) => None,
        // `acpmux send` at a shell, through a peer, or with `--no-wait` through this daemon's
        // outbox (`server/outbox.rs`, which connects as `acpmux-outbox`).
        None if ["acpmux-cli#", "acpmux-peer#", "acpmux-outbox#"]
            .iter()
            .any(|c| client.starts_with(c)) =>
        {
            name_prefixed(text)
        }
        None if client == "adopt" => cross_session(text),
        None => None,
    }
}

/// The senders of a turn of several messages, each once, in order: "a, b, c +2". `None` when
/// none is named.
fn senders<'a>(names: impl Iterator<Item = &'a str>) -> Option<String> {
    let mut senders: Vec<&str> = Vec::new();
    for from in names.map(str::trim) {
        if !from.is_empty() && !senders.contains(&from) {
            senders.push(from);
        }
    }
    match senders.len() {
        0 => None,
        n if n > 3 => senders.get(..3).map(|first| format!("{} +{}", first.join(", "), n - 3)),
        _ => Some(senders.join(", ")),
    }
}

/// The sender's own words in another agent's message: inside the envelope cmux wraps a cmux
/// agent message in (`rendered_body`), else the whole text (`inbox_digest.rs`).
pub(super) fn agent_words<'a>(text: &'a str, provenance: Option<&Value>) -> &'a str {
    let msg_id = provenance.and_then(|p| p.get("msgId")).and_then(Value::as_str);
    msg_id.and_then(|id| rendered_body(text, id)).unwrap_or(text)
}

/// The sender's words in a message as cmux renders it for the agent (`agent_message_prompt.rs`
/// `render`): what lies between the `---` line after its header and `--- end of message <id> ---`.
fn rendered_body<'a>(text: &'a str, msg_id: &str) -> Option<&'a str> {
    let text = text.trim();
    if !text.starts_with("[cmux agent message") {
        return None;
    }
    let start = text.find("\n---\n")? + "\n---\n".len();
    let end = text.rfind(&format!("\n--- end of message {msg_id} ---"))?;
    (start <= end).then(|| &text[start..end])
}

/// `[name] words`: a sender's name in brackets (a word or a few, as `coord-deputy` or
/// `claude-sr2/coordinator`) before its words. Claude Code's "[Request interrupted …]" and cmux's
/// own "[cmux agent message]" header are not a name.
fn name_prefixed(text: &str) -> Option<(String, String)> {
    let rest = text.trim().strip_prefix('[')?;
    let (name, after) = rest.split_once(']')?;
    if !after.starts_with(char::is_whitespace) {
        return None;
    }
    let words = after.trim();
    let named = name.chars().count() <= 64
        && !name.contains('\n')
        && name.split(' ').count() <= 4
        && name.split(' ').all(|w| {
            !w.is_empty() && w.chars().all(|c| c.is_alphanumeric() || "_.@/:-".contains(c))
        })
        && !name.starts_with("Request interrupted")
        && !name.starts_with("cmux agent message");
    (named && !words.is_empty()).then(|| (name.to_owned(), words.to_owned()))
}

/// Claude Code's `<cross-session-message from="…" from-name="…">words</cross-session-message>`,
/// when the prompt starts with it (after Claude Code's bookkeeping blocks).
fn cross_session(text: &str) -> Option<(String, String)> {
    let mut rest = text.trim();
    while let Some(tag) = ["system-reminder", "local-command-caveat", "user-prompt-submit-hook"]
        .into_iter()
        .find(|tag| rest.starts_with(&format!("<{tag}>")))
    {
        let close = format!("</{tag}>");
        rest = rest[rest.find(&close)? + close.len()..].trim_start();
    }
    let open = rest.strip_prefix("<cross-session-message")?;
    let (attributes, after) = open.split_once('>')?;
    let words = &after[..after.find("</cross-session-message>")?];
    let attribute = |key: &str| {
        let at = attributes.find(&format!(" {key}=\""))? + key.len() + 3;
        let value = attributes[at..].split('"').next()?.trim();
        (!value.is_empty()).then(|| decode_xml(value))
    };
    let name = attribute("from-name").or_else(|| attribute("from"))?;
    Some((name, decode_xml(words)))
}

/// The five named XML entities; numeric ones stay as written.
fn decode_xml(text: &str) -> String {
    text.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests;
