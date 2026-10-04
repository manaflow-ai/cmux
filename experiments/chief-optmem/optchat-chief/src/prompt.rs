//! The turn session's system prompt and the turn's prompt (sections 7 and 7.2).
//! Everything here is constant: the prompt and the tool list head every
//! cached prefix, so they hold no dates, no state and no per-turn text.

use serde_json::{Value, json};

/// The agent's name in the prompts (section 7.2: rename the agent).
pub const AGENT: &str = "Chief";

/// MASTER from section 7.2 with the agent renamed, and one deviation
/// (README): its line on messages sent mid-run says what the host does
/// (decision 2026-10-04) instead of "reach you between tool calls".
pub const MASTER: &str = "You are Chief, an AI agent that works for one user in a single chat that
never ends. Do the user's tasks yourself, with your tools, following
the user's instructions at the end of this prompt: they say who the
user is, how their files are organized and how they want work done.
Use subagents only when the user asks for them.

You keep no memory between turns. Each turn starts with the view below,
followed by the user's new message. Summaries keep little of tool
output, so say in your reply what you learned that will matter later.
A message the user sends while you work interrupts you at once, even
mid-thought; a tool call already running finishes first, then you go on
with the message.

Subagents and computer tasks run in the background. Each one's report
reaches you as a message starting \"[id] \": between your tool calls
while you work, or as a new turn once yours has ended. So never wait
for one (no sleep, no polling): go on, or end your turn and tell the
user what is running.";

/// VIEW_DOC, verbatim from section 7.2 with the agent renamed.
pub const VIEW_DOC: &str =
    "The view: the whole chat between Chief and the user, oldest first, inside
<chat> tags, as one-line summaries. Each line is

  id+n|text   the n messages from id on, summarized (newlines shown as spaces)

A summary tags each item with its kind: user (the user's words), talk
(Chief's replies), tool (Chief's tool calls), echo (their results), note
(memories from before this chat), or work (the report of a subagent or
a computer task, which the log holds as a user message starting
\"[id] \"). A short message is its own line, word for word. Recent lines
cover one message each; the older the messages, the more a line covers.
A message not summarized yet shows as \"(not summarized yet: zoom it)\".
No message appears in full, not even the last ones.

Navigating: zoom(id, n) opens line id+n into the two lines of n/2
messages it was made from; zoom(id, 1) gives message id in full. Zoom
whenever a summary only mentions something you need, such as what your
last reply said, a decision, a past attempt or where a file is, before
you act, guess or ask. date(id) gives the date and time of message id.";

/// The third part of the system prompt, where section 7.2 puts the user's own
/// instructions file: how this Chief works inside cmux. It names no user and
/// holds nothing that changes per turn.
pub const CMUX_INSTRUCTIONS: &str = "# Instructions

You run inside cmux, a terminal for coding agents; the user talks to you in
cmux Home, and your final reply of each turn is posted there.

- Workspaces, panes, terminals and browsers: use the `cmux` MCP tools when
  you have them, else the `cmux` CLI from your shell (`cmux --help`). It
  drives the user's cmux app; it never moves the user's focus unless you ask
  for it. Never close or change workspaces the user did not ask about.
- Subagents: start one with
  `chief agents spawn --name NAME --cwd DIR [--harness claude-sr|codex] \"task\"`.
  It runs in the background as an acpmux session; when it ends a turn, its
  final reply reaches you as a message \"[NAME] report\". Steer it with
  `chief agents prompt NAME \"text\"`, see yours with `chief agents list`,
  answer its permission requests with `chief agents allow NAME [OPTION_ID]`
  or `chief agents deny NAME` (ask the user first for anything destructive
  or outward-facing). Start agents only this way: only these report back.
- The tools `zoom` and `date` (MCP server `optchat`) read your memory.";

/// The system prompt (the session's CLAUDE.md): MASTER, VIEW_DOC, the cmux
/// section, then the user's own instructions file (section 7.2), read once
/// per host start so every turn's prompt stays byte-identical.
pub fn claude_md(user: Option<&str>) -> String {
    match user.map(str::trim).filter(|u| !u.is_empty()) {
        Some(user) => format!("{MASTER}\n\n{VIEW_DOC}\n\n{CMUX_INSTRUCTIONS}\n\n{user}\n"),
        None => format!("{MASTER}\n\n{VIEW_DOC}\n\n{CMUX_INSTRUCTIONS}\n"),
    }
}

/// The user's instructions file, `$MUX_HOME/optchat/AGENTS.md` (None when
/// missing or empty).
pub fn user_instructions(path: &std::path::Path) -> Option<String> {
    std::fs::read_to_string(path)
        .ok()
        .filter(|t| !t.trim().is_empty())
}

/// Tool descriptions, verbatim from section 7.1.
pub const ZOOM_DESCRIPTION: &str = "Open the line id+n of the view into the two lines of n/2 under it; n = 1 gives the message whole.";
pub const DATE_DESCRIPTION: &str = "The date and time of message id.";

/// The turn's user message (section 7): the view rendered before the new
/// messages were logged, then the new messages joined by a blank line.
///
/// The view goes as up to four text blocks, cut at its cache marks (section 8:
/// the last line end before 50k, 80k and 100k characters), so a harness that
/// puts a breakpoint on each block lets the next turn read the unchanged
/// start of the view. Deviation: acpmux's Claude Code path forwards text
/// blocks without `cache_control`, and Claude Code places its own breakpoints
/// (never inside the view), so with claude-sr no breakpoint lands on these
/// cuts yet and a turn rewrites the view instead of reading it. Each turn's
/// host.log line (`turn::usage_line`) shows what the first request read.
pub fn turn_blocks(view: &str, texts: &[String]) -> Vec<Value> {
    let mut blocks: Vec<Value> = optchat_core::cache_pieces(view)
        .into_iter()
        .map(|piece| json!({"type": "text", "text": piece}))
        .collect();
    blocks.push(json!({"type": "text", "text": texts.join("\n\n")}));
    blocks
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_md_is_byte_stable_and_names_no_user() {
        assert_eq!(claude_md(None), claude_md(None));
        let text = claude_md(None);
        assert!(!text.contains("OptChat"), "the agent is renamed");
        assert!(text.starts_with("You are Chief, an AI agent"));
        assert!(text.contains("\n\nThe view: the whole chat between Chief and the user"));
        assert!(text.contains("before\nyou act, guess or ask."));
        assert!(text.ends_with("read your memory.\n"));
    }

    /// Audit round 2: the user's own instructions file comes last (section 7.2).
    #[test]
    fn the_users_instructions_come_last() {
        let text = claude_md(Some("I keep worktrees under ~/w.\n"));
        assert!(text.starts_with("You are Chief"));
        assert!(text.ends_with("read your memory.\n\nI keep worktrees under ~/w.\n"));
        assert_eq!(claude_md(Some("  \n")), claude_md(None));
    }

    #[test]
    fn the_turn_prompt_is_two_blocks() {
        let blocks = turn_blocks("<chat>\n</chat>", &["one".into(), "two".into()]);
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0]["text"], "<chat>\n</chat>");
        assert_eq!(blocks[1]["text"], "one\n\ntwo");
    }
}
