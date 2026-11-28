//! A pull request's GitHub review comments as review threads, so a comment
//! someone left on GitHub reaches the agent the way a diff page comment does,
//! and the agent's answer goes back to that GitHub thread.
//!
//! `import` takes GitHub's review comments (`GET
//! repos/OWNER/REPO/pulls/N/comments`, one object each) and keeps each
//! top-level one as a thread, its `in_reply_to_id` answers as that thread's
//! replies. Each thread and reply carries `github: {id, url, author}`, the
//! daemon's own field (a page save keeps it, `thread::THREAD_FIELDS`), which
//! is what a re-import matches on: the same comment is never imported twice,
//! and a thread's id is `gh_<comment id>`, so a re-import after the thread
//! was cleared makes the same thread again.
//!
//! An imported thread is never a draft of a new review. `agent_replies` names
//! the agent replies of an imported thread that GitHub has not yet got, which
//! `git.review.post` posts as replies to that thread and `mark_posted` marks.

use serde_json::{Map, Value, json};

use super::thread::MAX_REPLIES;
use super::{File, MAX_COMMENT_BYTES, MAX_COMMENTS};

/// `gh api --jq '.[]'` output: one JSON object a line; other lines are skipped.
pub(in super::super) fn comment_lines(text: &str) -> Vec<Value> {
    text.lines()
        .filter_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
        .filter(Value::is_object)
        .collect()
}

/// What one import added.
#[derive(Debug, Default, PartialEq, Eq)]
pub(in super::super) struct Imported {
    pub(in super::super) threads: usize,
    pub(in super::super) replies: usize,
}

/// The GitHub comment id a thread or reply was imported from (or posted as).
pub(in super::super) fn github_id(value: &Map<String, Value>) -> Option<u64> {
    value.get("github")?.get("id")?.as_u64()
}

fn github_field(comment: &Map<String, Value>) -> Value {
    let text = |name: &str| comment.get(name).and_then(Value::as_str).unwrap_or_default();
    let author = comment
        .get("user")
        .and_then(|user| user.get("login"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    json!({
        "id": comment.get("id").and_then(Value::as_u64),
        "url": text("html_url"),
        "author": author,
    })
}

/// The line a GitHub comment is on: its last diff hunk line, without the
/// diff's `+`, `-` or space.
fn line_text(comment: &Map<String, Value>) -> String {
    let hunk = comment.get("diff_hunk").and_then(Value::as_str).unwrap_or_default();
    let last = hunk.lines().rev().find(|line| !line.starts_with("@@")).unwrap_or_default();
    last.strip_prefix(['+', '-', ' ']).unwrap_or(last).trim_end_matches('\r').to_string()
}

fn line(comment: &Map<String, Value>, names: &[&str]) -> Option<u64> {
    names.iter().find_map(|name| comment.get(*name).and_then(Value::as_u64)).filter(|n| *n > 0)
}

/// Adds the comments not yet kept: top-level ones as threads, answers as
/// replies of their thread. A comment already imported (by its GitHub id),
/// one with no body, an answer whose thread is not kept, and anything past a
/// thread's or root's bound are skipped.
pub(in super::super) fn import(file: &mut File, comments: &[Value], now: &str) -> Imported {
    let mut sorted: Vec<&Map<String, Value>> = comments
        .iter()
        .filter_map(Value::as_object)
        .filter(|comment| comment.get("id").and_then(Value::as_u64).is_some())
        .collect();
    // Oldest first, so a thread is kept before its answers.
    sorted.sort_by_key(|comment| comment.get("id").and_then(Value::as_u64).unwrap_or_default());
    let mut imported = Imported::default();
    for comment in sorted {
        let Some(id) = comment.get("id").and_then(Value::as_u64) else { continue };
        let body = comment.get("body").and_then(Value::as_str).unwrap_or_default().trim();
        if body.is_empty() || known(file, id) {
            continue;
        }
        let created = comment.get("created_at").and_then(Value::as_str).unwrap_or(now);
        match comment.get("in_reply_to_id").and_then(Value::as_u64) {
            Some(parent) => {
                let Some(thread) =
                    file.comments.iter_mut().find(|thread| github_id(thread) == Some(parent))
                else {
                    continue;
                };
                let mut replies =
                    thread.get("replies").and_then(Value::as_array).cloned().unwrap_or_default();
                if replies.len() >= MAX_REPLIES {
                    continue;
                }
                replies.push(json!({
                    "id": format!("dr_gh_{id}"),
                    "author": "reviewer",
                    "text": body,
                    "createdAt": created,
                    "github": github_field(comment),
                }));
                let mut updated = thread.clone();
                updated.insert("replies".into(), Value::Array(replies));
                updated.insert("updatedAt".into(), json!(now));
                if fits(&updated) {
                    *thread = updated;
                    imported.replies += 1;
                }
            }
            None => {
                if file.comments.len() >= MAX_COMMENTS {
                    continue;
                }
                let path = comment.get("path").and_then(Value::as_str).unwrap_or_default();
                let Some(end) = line(comment, &["line", "original_line"]) else { continue };
                let start = line(comment, &["start_line", "original_start_line"]).unwrap_or(end);
                let side = match comment.get("side").and_then(Value::as_str) {
                    Some("LEFT") => "deletions",
                    _ => "additions",
                };
                let thread = Map::from_iter([
                    ("id".into(), json!(format!("gh_{id}"))),
                    ("filePath".into(), json!(path)),
                    ("side".into(), json!(side)),
                    ("startLine".into(), json!(start.min(end))),
                    ("endLine".into(), json!(end)),
                    ("lineText".into(), json!(line_text(comment))),
                    ("message".into(), json!(body)),
                    ("createdAt".into(), json!(created)),
                    ("updatedAt".into(), json!(now)),
                    ("github".into(), github_field(comment)),
                ]);
                if fits(&thread) && !path.is_empty() {
                    file.comments.push(thread);
                    imported.threads += 1;
                }
            }
        }
    }
    imported
}

fn fits(comment: &Map<String, Value>) -> bool {
    serde_json::to_vec(comment).map(|bytes| bytes.len()).unwrap_or(usize::MAX) <= MAX_COMMENT_BYTES
}

/// Whether a thread or reply already carries GitHub comment `id`.
fn known(file: &File, id: u64) -> bool {
    file.comments.iter().any(|thread| {
        github_id(thread) == Some(id)
            || thread.get("replies").and_then(Value::as_array).is_some_and(|replies| {
                replies
                    .iter()
                    .filter_map(Value::as_object)
                    .any(|reply| github_id(reply) == Some(id))
            })
    })
}

/// One agent reply GitHub has not got: the GitHub comment it answers, the
/// thread and reply ids, and its text.
#[derive(Debug, PartialEq, Eq)]
pub(in super::super) struct Outgoing {
    pub(in super::super) github_id: u64,
    pub(in super::super) thread: String,
    pub(in super::super) reply: String,
    pub(in super::super) text: String,
}

/// The agent replies of the imported threads `ids` names that carry no
/// GitHub comment yet, oldest first.
pub(in super::super) fn agent_replies(file: &File, ids: &[String]) -> Vec<Outgoing> {
    let mut outgoing = Vec::new();
    for thread in &file.comments {
        let Some(thread_id) = thread.get("id").and_then(Value::as_str) else { continue };
        let Some(github) = github_id(thread) else { continue };
        if !ids.iter().any(|id| id == thread_id) {
            continue;
        }
        let replies = thread.get("replies").and_then(Value::as_array);
        for reply in replies.into_iter().flatten().filter_map(Value::as_object) {
            let text = |name: &str| reply.get(name).and_then(Value::as_str).unwrap_or_default();
            if text("author") != "agent" || reply.contains_key("github") || text("text").is_empty()
            {
                continue;
            }
            outgoing.push(Outgoing {
                github_id: github,
                thread: thread_id.to_owned(),
                reply: text("id").to_owned(),
                text: text("text").to_owned(),
            });
        }
    }
    outgoing
}

/// Marks `reply` of `thread` as posted to GitHub as `posted` (a review
/// comment object), so it is never posted again or re-imported.
pub(in super::super) fn mark_posted(
    file: &mut File,
    thread: &str,
    reply: &str,
    posted: &Value,
) -> bool {
    let Some(comment) = file
        .comments
        .iter_mut()
        .find(|comment| comment.get("id").and_then(Value::as_str) == Some(thread))
    else {
        return false;
    };
    let mut replies = comment.get("replies").and_then(Value::as_array).cloned().unwrap_or_default();
    let posted = posted.as_object().map(github_field).unwrap_or_else(|| json!({}));
    let mut marked = false;
    for entry in replies.iter_mut().filter_map(Value::as_object_mut) {
        if entry.get("id").and_then(Value::as_str) == Some(reply) {
            entry.insert("github".into(), posted.clone());
            marked = true;
        }
    }
    comment.insert("replies".into(), Value::Array(replies));
    marked
}

#[cfg(test)]
#[path = "github_tests.rs"]
mod tests;
