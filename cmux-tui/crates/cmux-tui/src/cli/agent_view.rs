//! `cmux agent view <chat>`: a Claude Code or Codex chat in a cmux NEXT tab that shows it and
//! follows the app that runs it, without running, resuming or writing to it, until Take Over.
//! The app's `agentChat.view` action (CLI name `agent view`, argument `key`) opens it, the same
//! opener an All chats row's View Only item calls; this only turns the positional chat the
//! words name into that argument. The chat is an index key (`claude-code:<id>`, `codex:<id>`),
//! a transcript path (a Claude Code `<id>.jsonl`, a Codex `rollout-…-<id>.jsonl`), or a bare
//! session id, found under `~/.claude/projects` or else taken as a Codex thread.
//! `agent view show|ensure|…` stay the sidebar view grammar: a chat names a `:`, a path or an id.

use std::path::{Path, PathBuf};

const ACTION: &str = "agent view";

/// The app action and its arguments for `agent view <chat> [flags]`, or None for other words.
pub(super) fn action(command_args: &[String]) -> Option<(String, Vec<String>)> {
    let [scope, view, chat, rest @ ..] = command_args else { return None };
    if scope != "agent" || view != "view" || chat.starts_with('-') {
        return None;
    }
    let key = chat_key(chat, claude_projects().as_deref())?;
    let mut args = vec!["--key".to_owned(), key];
    args.extend(rest.iter().cloned());
    Some((ACTION.to_owned(), args))
}

/// The index key `chat` names, or None when it names no chat (a sidebar view verb).
fn chat_key(chat: &str, claude_projects: Option<&Path>) -> Option<String> {
    if let Some((harness, id)) = chat.split_once(':')
        && matches!(harness, "claude-code" | "codex")
        && !id.is_empty()
    {
        return Some(chat.to_owned());
    }
    if chat.ends_with(".jsonl") {
        let stem = Path::new(chat).file_stem()?.to_str()?;
        return Some(match stem.strip_prefix("rollout-") {
            Some(rest) => format!("codex:{}", rest.get(rest.len().checked_sub(36)?..)?),
            None => format!("claude-code:{stem}"),
        });
    }
    if !is_session_id(chat) {
        return None;
    }
    let claude = claude_projects.is_some_and(|projects| {
        std::fs::read_dir(projects)
            .into_iter()
            .flatten()
            .flatten()
            .any(|project| project.path().join(format!("{chat}.jsonl")).is_file())
    });
    Some(format!("{}:{chat}", if claude { "claude-code" } else { "codex" }))
}

/// A UUID-shaped session id: 36 characters, hex digits and four dashes.
fn is_session_id(text: &str) -> bool {
    text.len() == 36
        && text.chars().enumerate().all(|(index, ch)| match index {
            8 | 13 | 18 | 23 => ch == '-',
            _ => ch.is_ascii_hexdigit(),
        })
}

fn claude_projects() -> Option<PathBuf> {
    let config = std::env::var_os("CLAUDE_CONFIG_DIR")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".claude")))?;
    Some(config.join("projects"))
}

#[cfg(test)]
mod tests;
