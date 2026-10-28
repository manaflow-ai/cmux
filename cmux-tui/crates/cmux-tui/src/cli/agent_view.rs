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
        cmux_blocking::fs::read_dir(projects).into_iter().flatten().flatten().any(|project| {
            cmux_blocking::fs::metadata(project.path().join(format!("{chat}.jsonl")))
                .is_ok_and(|metadata| metadata.is_file())
        })
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
mod tests {
    use super::*;

    const ID: &str = "0199f0a2-7c3e-7d41-9b8a-2f6c1d4e5a6b";

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn agent_view_takes_a_chat_key_path_or_id() {
        let none: Option<&Path> = None;
        assert_eq!(chat_key(&format!("codex:{ID}"), none), Some(format!("codex:{ID}")));
        assert_eq!(
            chat_key(&format!("/Users/me/.claude/projects/-src-app/{ID}.jsonl"), none),
            Some(format!("claude-code:{ID}"))
        );
        assert_eq!(
            chat_key(&format!("sessions/2026/10/18/rollout-2026-10-18T09-00-00-{ID}.jsonl"), none),
            Some(format!("codex:{ID}"))
        );
        // A bare id is Claude Code's when its transcript is under ~/.claude/projects.
        let root = std::env::temp_dir().join(format!("cmux-agent-view-{}", std::process::id()));
        std::fs::create_dir_all(root.join("-src-app")).unwrap();
        assert_eq!(chat_key(ID, Some(&root)), Some(format!("codex:{ID}")));
        std::fs::write(root.join(format!("-src-app/{ID}.jsonl")), "").unwrap();
        assert_eq!(chat_key(ID, Some(&root)), Some(format!("claude-code:{ID}")));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn sidebar_view_verbs_are_not_chats() {
        for verb in ["show", "ensure", "attach", "input", "resize", "reload", "opencode:abc"] {
            assert_eq!(action(&words(&format!("agent view {verb}"))), None, "{verb}");
        }
        assert_eq!(action(&words("agent view --key codex:x")), None);
        assert_eq!(
            action(&words(&format!("agent view codex:{ID} --no-wait"))),
            Some((ACTION.to_owned(), words(&format!("--key codex:{ID} --no-wait"))))
        );
    }
}
