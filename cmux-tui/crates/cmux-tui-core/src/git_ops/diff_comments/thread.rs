//! Review threads: a comment with its replies and whether it is resolved,
//! kept after a send so the agent's answer comes back to it.
//!
//! A comment's thread fields are the daemon's, beside the page's own JSON:
//! `replies` (`[{id, author, text, createdAt, sentIn?}]`, oldest first),
//! `resolved` (bool), and the marks of what already went to the agent:
//! `sentIn` (the prompt id that carried the comment, cleared when its message
//! is edited) and `resolveSent` (the `resolved` value the agent last read). A
//! save from the page keeps them; only `diff.comments.thread` and a threaded
//! `diff.comments.send` change them.
//!
//! `diff.comments.thread {root, id, reply?, resolved?}` adds one reply (by
//! `reviewer`, the person, or `agent`) and/or sets `resolved`. The agent's
//! answer to a thread is a reply by `agent`, which it posts with
//! `cmux git comments reply ID`.
//!
//! A threaded send (`diff.comments.send` with `threads: true`) writes the
//! prompt here, from the store: every named thread with something the agent
//! has not read (a comment never sent, a reviewer reply never sent, a resolve
//! or reopen), each under its id with the command that answers it. Once acpmux
//! takes the prompt, exactly what it carried is marked sent, and nothing is
//! removed.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use super::{File, MAX_COMMENT_BYTES, hex};
use crate::resource::ResourceError;

const OPERATION: &str = "diff.comments.thread";
/// The daemon's own fields of a comment: a page save never sets them.
pub(super) const THREAD_FIELDS: [&str; 5] =
    ["replies", "resolved", "resolvedAt", "sentIn", "resolveSent"];
/// The most replies one thread keeps.
pub(super) const MAX_REPLIES: usize = 200;
/// The longest reply text, in bytes.
pub(super) const MAX_REPLY_BYTES: usize = 16 * 1024;

/// Who wrote a reply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Author {
    Reviewer,
    Agent,
}

impl Author {
    fn wire(self) -> &'static str {
        match self {
            Self::Reviewer => "reviewer",
            Self::Agent => "agent",
        }
    }
}

/// What one `diff.comments.thread` asks for.
#[derive(Debug)]
pub(super) struct Change {
    pub(super) id: String,
    pub(super) reply: Option<(Author, String)>,
    pub(super) resolved: Option<bool>,
}

/// Reads `{id, reply?, author?, resolved?}`; at least one of reply and
/// resolved. `author` (reviewer by default) says who wrote `reply`.
pub(super) fn change(fields: &Map<String, Value>) -> Result<Change, ResourceError> {
    let id = fields.get("id").and_then(Value::as_str).unwrap_or_default();
    if !(1..=128).contains(&id.len()) {
        return Err(ResourceError::validation_invalid(Some("id"), "id must name a comment"));
    }
    let author = match fields.get("author") {
        None | Some(Value::Null) => Author::Reviewer,
        Some(Value::String(author)) if author == "reviewer" => Author::Reviewer,
        Some(Value::String(author)) if author == "agent" => Author::Agent,
        Some(_) => {
            return Err(ResourceError::validation_invalid(
                Some("author"),
                "author must be reviewer or agent",
            ));
        }
    };
    let reply = match fields.get("reply") {
        None | Some(Value::Null) => None,
        Some(Value::String(text)) if !text.trim().is_empty() && text.len() <= MAX_REPLY_BYTES => {
            Some((author, text.clone()))
        }
        Some(_) => {
            return Err(ResourceError::validation_invalid(
                Some("reply"),
                format!("reply must be 1 to {MAX_REPLY_BYTES} bytes, not blank"),
            ));
        }
    };
    let resolved = match fields.get("resolved") {
        None | Some(Value::Null) => None,
        Some(Value::Bool(resolved)) => Some(*resolved),
        Some(_) => {
            return Err(ResourceError::validation_invalid(
                Some("resolved"),
                "resolved must be true or false",
            ));
        }
    };
    if reply.is_none() && resolved.is_none() {
        return Err(ResourceError::validation_invalid(
            Some("reply"),
            "a thread change adds a reply, sets resolved, or both",
        ));
    }
    Ok(Change { id: id.to_owned(), reply, resolved })
}

/// Applies `change` to its comment. Returns `{comment}`; an unknown id is
/// `operation.failed` `no_comment`.
pub(super) fn apply(
    file: &mut File,
    root: &str,
    key: &str,
    change: Change,
    now: &str,
) -> Result<(Value, bool), ResourceError> {
    let Some(comment) = file
        .comments
        .iter_mut()
        .find(|comment| comment.get("id").and_then(Value::as_str) == Some(change.id.as_str()))
    else {
        let message = format!("no comment {} under this root", change.id);
        return Err(ResourceError::operation_failed(
            OPERATION,
            "no_comment",
            json!({"message": message}),
        ));
    };
    let mut updated = comment.clone();
    if let Some((author, text)) = change.reply {
        let mut replies = replies(&updated);
        if replies.len() >= MAX_REPLIES {
            let message = format!("this thread already keeps {MAX_REPLIES} replies");
            return Err(ResourceError::operation_failed(
                OPERATION,
                "too_many_replies",
                json!({"message": message, "maximum": MAX_REPLIES}),
            ));
        }
        replies.push(json!({
            "id": reply_id(root, key),
            "author": author.wire(),
            "text": text,
            "createdAt": now,
        }));
        updated.insert("replies".into(), Value::Array(replies));
    }
    if let Some(resolved) = change.resolved {
        updated.insert("resolved".into(), Value::Bool(resolved));
        if resolved {
            updated.insert("resolvedAt".into(), Value::String(now.to_owned()));
        } else {
            updated.remove("resolvedAt");
        }
    }
    updated.insert("updatedAt".into(), Value::String(now.to_owned()));
    let bytes = serde_json::to_vec(&updated).map(|bytes| bytes.len()).unwrap_or(usize::MAX);
    if bytes > MAX_COMMENT_BYTES {
        return Err(ResourceError::validation_invalid(
            Some("reply"),
            format!(
                "comment_too_large: a comment and its thread are at most {MAX_COMMENT_BYTES} bytes"
            ),
        ));
    }
    *comment = updated.clone();
    Ok((json!({"comment": updated}), true))
}

/// A page save of a comment that exists keeps its thread: the daemon's
/// fields come from the stored comment, never from the page. An edited
/// message is the agent's to read again, so `sentIn` goes.
pub(super) fn keep_thread(stored: Option<&Map<String, Value>>, comment: &mut Map<String, Value>) {
    for field in THREAD_FIELDS {
        comment.remove(field);
    }
    let Some(stored) = stored else { return };
    for field in THREAD_FIELDS {
        if let Some(value) = stored.get(field) {
            comment.insert(field.into(), value.clone());
        }
    }
    if stored.get("message") != comment.get("message") {
        comment.remove("sentIn");
    }
}

fn replies(comment: &Map<String, Value>) -> Vec<Value> {
    comment.get("replies").and_then(Value::as_array).cloned().unwrap_or_default()
}

fn reply_id(root: &str, key: &str) -> String {
    let digest = Sha256::digest(format!("diff-comment-reply\0{root}\0{key}").as_bytes());
    format!("dr_{}", hex(digest.get(..16).unwrap_or_default()))
}

fn resolved(comment: &Map<String, Value>) -> bool {
    comment.get("resolved").and_then(Value::as_bool).unwrap_or(false)
}

/// What a thread holds that the agent has not read.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Unread {
    /// The comment itself (never sent, or edited since).
    pub(super) comment: bool,
    /// The ids of reviewer replies never sent.
    pub(super) replies: Vec<String>,
    /// A resolve or reopen the agent has not read: the new value.
    pub(super) resolved: Option<bool>,
    /// The message the prompt carried, so a later edit is sent again.
    pub(super) message: Option<Value>,
}

impl Unread {
    fn is_empty(&self) -> bool {
        !self.comment && self.replies.is_empty() && self.resolved.is_none()
    }
}

pub(super) fn unread(comment: &Map<String, Value>) -> Unread {
    let resolved_now = resolved(comment);
    let sent = comment.get("sentIn").is_some_and(Value::is_string);
    // A comment never sent and already resolved has nothing to ask.
    let new_comment = !sent && !resolved_now;
    let replies = replies(comment)
        .iter()
        .filter(|reply| reply.get("author").and_then(Value::as_str) == Some("reviewer"))
        .filter(|reply| reply.get("sentIn").is_none())
        .filter_map(|reply| reply.get("id").and_then(Value::as_str).map(str::to_owned))
        .collect();
    let read = comment.get("resolveSent").and_then(Value::as_bool).unwrap_or(false);
    let resolved = (sent && read != resolved_now).then_some(resolved_now);
    Unread {
        comment: new_comment,
        replies,
        resolved,
        message: new_comment.then(|| comment.get("message").cloned().unwrap_or(Value::Null)),
    }
}

/// One thread a prompt carries, and what of it.
#[derive(Debug)]
pub(super) struct Carried {
    pub(super) id: String,
    pub(super) unread: Unread,
}

/// The threaded prompt for `ids` (store order), and what it carries; `None`
/// when none of them has anything unread.
pub(super) fn render(
    file: &File,
    root: &str,
    ids: &[String],
    note: Option<&str>,
) -> Option<(String, Vec<Carried>)> {
    let mut carried = Vec::new();
    let mut sections = Vec::new();
    let mut files = Vec::new();
    let mut places = false;
    for comment in file.sorted() {
        let Some(id) = comment.get("id").and_then(Value::as_str) else { continue };
        if !ids.iter().any(|named| named == id) {
            continue;
        }
        let unread = unread(comment);
        if unread.is_empty() {
            continue;
        }
        let path = match surface(comment) {
            Some(surface) => {
                places = true;
                surface
            }
            None => comment.get("filePath").and_then(Value::as_str).unwrap_or("(no file)"),
        };
        if !files.contains(&path) {
            files.push(path);
        }
        sections.push(section(comment, id, &unread));
        carried.push(Carried { id: id.to_owned(), unread });
    }
    if carried.is_empty() {
        return None;
    }
    // A browser or terminal thread is a place, not a file.
    let noun = if places { "place" } else { "file" };
    let root_arg = shell_quote(root);
    let threads = carried.len();
    let mut text = format!(
        "Code review of {root}: {threads} thread{} across {} {noun}{}.\n\n\
         Answer each thread in that thread, not only here, with\n\
         `cmux git comments reply <thread id> --root {root_arg} --text '<your answer>'`\n\
         and resolve a thread you finished with\n\
         `cmux git comments resolve <thread id> --root {root_arg}`.\n",
        if threads == 1 { "" } else { "s" },
        files.len(),
        if files.len() == 1 { "" } else { "s" },
    );
    if let Some(note) = note.map(str::trim).filter(|note| !note.is_empty()) {
        text.push_str(&format!("\nThe reviewer's note: {note}\n"));
    }
    for section in sections {
        text.push('\n');
        text.push_str(&section);
    }
    Some((text, carried))
}

fn section(comment: &Map<String, Value>, id: &str, unread: &Unread) -> String {
    let text = |name: &str| comment.get(name).and_then(Value::as_str).unwrap_or_default();
    let line = |name: &str| comment.get(name).and_then(Value::as_u64);
    let place = match (line("startLine"), line("endLine")) {
        (Some(start), Some(end)) if start != end => format!("lines {start}-{end}"),
        (_, Some(line)) | (Some(line), None) => format!("line {line}"),
        (None, None) => "the file".to_owned(),
    };
    let version = if text("side") == "deletions" { "old version" } else { "new version" };
    let mut out = match surface(comment) {
        // A browser or terminal comment: where it is, as the surface named it.
        Some(surface) => match comment.get("place").and_then(Value::as_str).map(one_line) {
            Some(place) if !place.is_empty() => format!("## Thread {id}: {surface} {place}\n"),
            _ => format!("## Thread {id}: {surface}\n"),
        },
        None => format!("## Thread {id}: {} {place} ({version})\n", text("filePath")),
    };
    if unread.comment {
        match comment.get("submissionText").and_then(Value::as_str).map(str::trim) {
            Some(block) if !block.is_empty() => out.push_str(&format!("\n{block}\n")),
            _ => {
                let quoted = text("lineText");
                if !quoted.is_empty() {
                    out.push_str(&format!("\n> {quoted}\n"));
                }
                out.push_str(&format!("\n{}\n", text("message")));
            }
        }
    } else {
        out.push_str("\nEarlier in this thread:\n");
        out.push_str(&format!("- reviewer: {}\n", one_line(text("message"))));
        for reply in replies(comment) {
            let rid = reply.get("id").and_then(Value::as_str).unwrap_or_default();
            if unread.replies.iter().any(|new| new == rid) {
                continue;
            }
            let author = reply.get("author").and_then(Value::as_str).unwrap_or("reviewer");
            let said = reply.get("text").and_then(Value::as_str).unwrap_or_default();
            out.push_str(&format!("- {author}: {}\n", one_line(said)));
        }
    }
    let new: Vec<_> = replies(comment)
        .into_iter()
        .filter(|reply| {
            reply
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|rid| unread.replies.iter().any(|new| new == rid))
        })
        .collect();
    if !new.is_empty() {
        out.push_str("\nNew from the reviewer:\n");
        for reply in new {
            let said = reply.get("text").and_then(Value::as_str).unwrap_or_default();
            out.push_str(&format!("- {}\n", one_line(said)));
        }
    }
    match unread.resolved {
        Some(true) if !unread.comment && unread.replies.is_empty() => {
            out.push_str("\nThe reviewer resolved this thread; it needs no answer.\n");
        }
        Some(true) => out.push_str("\nThe reviewer resolved this thread.\n"),
        Some(false) => out.push_str("\nThe reviewer reopened this thread.\n"),
        None => {}
    }
    out
}

/// The surface a comment not on a diff came from (`surface`: browser or
/// terminal), as the prompt names it; `None` for a diff comment.
fn surface(comment: &Map<String, Value>) -> Option<&'static str> {
    match comment.get("surface").and_then(Value::as_str) {
        Some("browser") => Some("browser page"),
        Some("terminal") => Some("terminal"),
        _ => None,
    }
}

/// One line of a reply, for a thread's history.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `text` as one single-quoted shell word.
fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// Marks what `carried` held as read by the agent in `prompt_id`: a comment
/// whose message is still the one sent gets `sentIn`, each carried reply gets
/// `sentIn`, and `resolveSent` takes the resolve it carried. Returns the ids
/// of the threads marked.
pub(super) fn mark_sent(file: &mut File, carried: &[Carried], prompt_id: &str) -> Vec<String> {
    let mut marked = Vec::new();
    for thread in carried {
        let Some(comment) = file
            .comments
            .iter_mut()
            .find(|comment| comment.get("id").and_then(Value::as_str) == Some(thread.id.as_str()))
        else {
            continue;
        };
        let mut changed = false;
        if thread.unread.comment
            && thread.unread.message.as_ref()
                == Some(comment.get("message").unwrap_or(&Value::Null))
        {
            comment.insert("sentIn".into(), Value::String(prompt_id.to_owned()));
            changed = true;
        }
        if !thread.unread.replies.is_empty() {
            let mut replies = replies(comment);
            for reply in replies.iter_mut() {
                let carried = reply
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|rid| thread.unread.replies.iter().any(|new| new == rid));
                if carried && let Some(reply) = reply.as_object_mut() {
                    reply.insert("sentIn".into(), Value::String(prompt_id.to_owned()));
                    changed = true;
                }
            }
            comment.insert("replies".into(), Value::Array(replies));
        }
        if let Some(resolved) = thread.unread.resolved {
            comment.insert("resolveSent".into(), Value::Bool(resolved));
            changed = true;
        }
        // A comment sent resolved-or-open: the agent has read that state too.
        if thread.unread.comment && !comment.contains_key("resolveSent") {
            comment.insert("resolveSent".into(), Value::Bool(resolved(comment)));
        }
        if changed {
            marked.push(thread.id.clone());
        }
    }
    marked
}

#[cfg(test)]
#[path = "thread_tests.rs"]
mod tests;
