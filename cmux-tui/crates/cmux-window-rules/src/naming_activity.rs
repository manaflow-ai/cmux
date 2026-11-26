//! Name from Activity (`workspace.nameFromActivity`): a short name for a
//! workspace from what its tabs show, asked of the cheapest model once, on
//! request. Leo, 2026-10-26: "a workspace to be renamed based off that
//! existing tabs there, the recent activity that's there. You know, just run
//! it on the cheapest model."
//!
//! The app reads the tabs, sends [`Activity::prompt`] through acpmux's
//! one-shot completion (`_acpmux/complete`) and applies [`name_from_reply`]
//! as a user rename. Only titles and short snippets go out, never a transcript.

use serde::{Deserialize, Serialize};

use super::{clean, is_newline, length, prefix};

/// The cheapest model; the completion runs on the person's own Claude login.
pub const MODEL: &str = "claude-haiku-5-5";
pub const HARNESS: &str = "claude";
/// Enough for five words; the reply is cut to [`MAX_WORDS`] anyway.
pub const MAX_TOKENS: u32 = 24;
/// The daemon's own limit is at most 60 s.
pub const TIMEOUT_MS: u32 = 20_000;
/// The most words a name keeps.
pub const MAX_WORDS: usize = 5;
/// The most characters a snippet keeps (a prompt, a title, a folder).
pub const SNIPPET_LIMIT: usize = 120;
/// The most prompts one chat sends: its newest.
pub const PROMPTS_PER_CHAT: usize = 3;
/// The most bytes a prompt takes, under `_acpmux/complete`'s 4096.
pub const PROMPT_BYTE_LIMIT: usize = 4000;
/// The most tabs read, front first.
pub const TAB_LIMIT: usize = 12;

/// What one tab shows, already trimmed ([`snippet`]).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Tab {
    Chat {
        #[serde(default)]
        title: Option<String>,
        #[serde(default)]
        prompts: Vec<String>,
    },
    Terminal {
        #[serde(default)]
        folder: Option<String>,
        #[serde(default)]
        title: Option<String>,
    },
    Browser {
        #[serde(default)]
        title: Option<String>,
    },
}

impl Tab {
    fn is_empty(&self) -> bool {
        match self {
            Tab::Chat { title, prompts } => title.is_none() && prompts.is_empty(),
            Tab::Terminal { folder, title } => folder.is_none() && title.is_none(),
            Tab::Browser { title } => title.is_none(),
        }
    }
}

/// What a workspace's tabs show, front first, at most [`TAB_LIMIT`], none empty.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Activity {
    pub tabs: Vec<Tab>,
}

impl Activity {
    pub fn new(tabs: impl IntoIterator<Item = Tab>) -> Self {
        Activity { tabs: tabs.into_iter().filter(|tab| !tab.is_empty()).take(TAB_LIMIT).collect() }
    }

    /// The completion's prompt: the instruction, then each tab's lines while
    /// they fit in [`PROMPT_BYTE_LIMIT`].
    pub fn prompt(&self) -> String {
        let mut text = [
            "Name this workspace in 2 to 5 words from what its tabs show.",
            "Reply with the name only: no quotes, no punctuation at the end, no explanation.",
            "",
            "Tabs:",
        ]
        .join("\n");
        for tab in &self.tabs {
            let lines = match tab {
                Tab::Chat { title, prompts } => {
                    std::iter::once(format!("- Agent chat{}", labelled(": ", title)))
                        .chain(prompts.iter().map(|prompt| format!("  - asked: {prompt}")))
                        .collect::<Vec<_>>()
                }
                Tab::Terminal { folder, title } => {
                    vec![format!("- Terminal{}{}", labelled(" in ", folder), labelled(": ", title))]
                }
                Tab::Browser { title } => vec![format!("- Web page{}", labelled(": ", title))],
            };
            let next = format!("{text}\n{}", lines.join("\n"));
            if next.len() > PROMPT_BYTE_LIMIT {
                break;
            }
            text = next;
        }
        text
    }
}

fn labelled(label: &str, value: &Option<String>) -> String {
    value.as_ref().map(|value| format!("{label}{value}")).unwrap_or_default()
}

/// One line of at most [`SNIPPET_LIMIT`] characters; `None` when empty.
pub fn snippet(text: Option<&str>) -> Option<String> {
    let line = text?
        .split(char::is_whitespace)
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    if line.is_empty() {
        return None;
    }
    if length(&line) > SNIPPET_LIMIT {
        Some(format!("{}…", prefix(&line, SNIPPET_LIMIT - 1)))
    } else {
        Some(line)
    }
}

/// Foundation's `CharacterSet.whitespaces`: tab and the space separators (Zs).
fn is_space(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// The name in the model's reply: its first line, without quotes, a "Name:"
/// label or a final period, at most [`MAX_WORDS`] words; `None` when nothing is left.
pub fn name_from_reply(reply: &str) -> Option<String> {
    let mut line = reply
        .split(is_newline)
        .filter(|line| !line.is_empty())
        .map(|line| line.trim_matches(is_space))
        .find(|line| !line.is_empty())?;
    if let Some(colon) = line.find(':')
        && line[..colon].to_lowercase() == "name"
    {
        line = &line[colon + 1..];
    }
    let trimmed = line
        .trim_matches(|c: char| "\"'`“”‘’*#".contains(c) || is_space(c))
        .trim_matches(|c: char| c == '.' || c == '!');
    let words = trimmed
        .split(char::is_whitespace)
        .filter(|word| !word.is_empty())
        .take(MAX_WORDS)
        .collect::<Vec<_>>();
    clean(Some(&words.join(" ")))
}

#[cfg(test)]
#[path = "naming_activity_tests.rs"]
mod tests;
