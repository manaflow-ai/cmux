//! Part of `Hub`; see `hub/mod.rs`. The pull requests a session opened: the URLs its
//! `gh pr create` tool calls printed, kept once each in its meta (`SessionMeta::pull_requests`)
//! so the sidebar's session tree counts every pull request a session opened, not only the one
//! of the branch its folder has checked out now.
//!
//! Harnesses report the command on the tool call and its output on later updates (Claude Code,
//! codex-acp), so a call that runs `gh pr create` is remembered until it ends
//! (`Session::pr_creates`). Output of any other command (`gh pr view`, `gh pr list`) is not read.

use std::sync::LazyLock;

use regex::Regex;

use super::*;

static GH_PR_CREATE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\bgh\s+pr\s+create\b").unwrap()); // crash-allow: constant pattern
static PULL_URL: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+\b").unwrap() // crash-allow: constant pattern
});

/// A session keeps at most this many; a runaway loop stops growing its meta here.
const MAX_PULL_REQUESTS: usize = 200;

/// The command a tool call runs, as its `rawInput` (a string or an argv) and title say.
fn command_text(update: &Value) -> String {
    let mut text = String::new();
    if let Some(title) = update.get("title").and_then(Value::as_str) {
        text.push_str(title);
    }
    for key in ["command", "cmd"] {
        match update.pointer(&format!("/rawInput/{key}")) {
            Some(Value::String(s)) => {
                text.push('\n');
                text.push_str(s);
            }
            Some(Value::Array(argv)) => {
                text.push('\n');
                text.push_str(&argv.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(" "));
            }
            _ => {}
        }
    }
    text
}

/// Notes a `tool_call` or `tool_call_update` into `m`: a call that runs `gh pr create` is
/// remembered, and the pull request URLs its output prints join `m.pull_requests`.
pub(super) fn absorb(session: &Session, update: &Value, m: &mut SessionMeta) {
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else {
        return;
    };
    let mut calls = session.pr_creates.lock().unwrap_or_else(|e| e.into_inner());
    if GH_PR_CREATE.is_match(&command_text(update)) {
        calls.insert(id.to_owned());
    }
    if !calls.contains(id) {
        return;
    }
    for key in ["content", "rawOutput"] {
        let Some(output) = update.get(key) else { continue };
        let text = output.to_string();
        for url in PULL_URL.find_iter(&text).map(|u| u.as_str()) {
            if m.pull_requests.len() < MAX_PULL_REQUESTS
                && !m.pull_requests.iter().any(|p| p == url)
            {
                m.pull_requests.push(url.to_owned());
            }
        }
    }
    if matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed")) {
        calls.remove(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_text_reads_a_string_an_argv_and_the_title() {
        assert!(
            GH_PR_CREATE
                .is_match(&command_text(&json!({"rawInput": {"command": "gh pr create --fill"}})))
        );
        assert!(GH_PR_CREATE.is_match(&command_text(
            &json!({"rawInput": {"command": ["bash", "-lc", "cd x && gh  pr create"]}})
        )));
        assert!(GH_PR_CREATE.is_match(&command_text(&json!({"title": "gh pr create -B main"}))));
        assert!(
            !GH_PR_CREATE
                .is_match(&command_text(&json!({"rawInput": {"command": "gh pr view 3"}})))
        );
    }

    #[test]
    fn pull_url_stops_at_the_number() {
        let text = r#"{"text":"https://github.com/manaflow-ai/cmux/pull/21814\n"} https://github.com/a/b/pull/3/files"#;
        let urls: Vec<_> = PULL_URL.find_iter(text).map(|u| u.as_str()).collect();
        assert_eq!(
            urls,
            ["https://github.com/manaflow-ai/cmux/pull/21814", "https://github.com/a/b/pull/3"]
        );
    }
}
