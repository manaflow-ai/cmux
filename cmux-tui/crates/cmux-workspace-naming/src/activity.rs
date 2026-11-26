//! Name from Activity (`workspace.nameFromActivity`): the prompt a small model names a workspace
//! from, its completion parameters, and the name read back from its reply.

use crate::text::{clean, is_horizontal_space, snippet};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The model that names a workspace.
pub const MODEL: &str = "claude-haiku-5-5";
/// The harness that runs it.
pub const HARNESS: &str = "claude";
/// The reply's token budget.
pub const MAX_TOKENS: u64 = 24;
/// How long the completion may take.
pub const TIMEOUT_MS: u64 = 20_000;
/// The most words a name keeps.
pub const MAX_WORDS: usize = 5;
/// The newest prompts read per chat.
pub const PROMPTS_PER_CHAT: usize = 3;
/// The most bytes the prompt takes.
pub const PROMPT_BYTE_LIMIT: usize = 4000;
/// The most tabs read.
pub const TAB_LIMIT: usize = 12;

/// What one tab shows.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Tab {
    /// An agent chat: its title and newest prompts.
    Chat {
        /// The chat's title.
        #[serde(default)]
        title: Option<String>,
        /// Its newest prompts, oldest first.
        #[serde(default)]
        prompts: Vec<String>,
    },
    /// A terminal: its folder and title.
    Terminal {
        /// The working directory.
        #[serde(default)]
        folder: Option<String>,
        /// The title.
        #[serde(default)]
        title: Option<String>,
    },
    /// A web page: its title.
    Browser {
        /// The title.
        #[serde(default)]
        title: Option<String>,
    },
}

impl Tab {
    /// Each text as one line of at most `SNIPPET_LIMIT` characters; the app reads the raw facts.
    pub fn snipped(&self) -> Tab {
        let one = |text: &Option<String>| snippet(text.as_deref());
        match self {
            Tab::Chat { title, prompts } => Tab::Chat {
                title: one(title),
                prompts: prompts.iter().filter_map(|prompt| snippet(Some(prompt))).collect(),
            },
            Tab::Terminal { folder, title } => {
                Tab::Terminal { folder: one(folder), title: one(title) }
            }
            Tab::Browser { title } => Tab::Browser { title: one(title) },
        }
    }

    /// Nothing to name from.
    pub fn is_empty(&self) -> bool {
        match self {
            Tab::Chat { title, prompts } => title.is_none() && prompts.is_empty(),
            Tab::Terminal { folder, title } => folder.is_none() && title.is_none(),
            Tab::Browser { title } => title.is_none(),
        }
    }
}

/// The tabs a workspace is named from: the non-empty ones, at most [`TAB_LIMIT`].
pub fn tabs(tabs: &[Tab]) -> Vec<Tab> {
    tabs.iter().filter(|tab| !tab.is_empty()).take(TAB_LIMIT).cloned().collect()
}

/// The prompt: the instruction, then one entry per tab while it fits [`PROMPT_BYTE_LIMIT`].
pub fn prompt(tabs: &[Tab]) -> String {
    let mut text = [
        "Name this workspace in 2 to 5 words from what its tabs show.",
        "Reply with the name only: no quotes, no punctuation at the end, no explanation.",
        "",
        "Tabs:",
    ]
    .join("\n");
    let titled =
        |title: &Option<String>| title.as_ref().map_or(String::new(), |t| format!(": {t}"));
    for tab in tabs {
        let lines = match tab {
            Tab::Chat { title, prompts } => {
                std::iter::once(format!("- Agent chat{}", titled(title)))
                    .chain(prompts.iter().map(|prompt| format!("  - asked: {prompt}")))
                    .collect::<Vec<_>>()
            }
            Tab::Terminal { folder, title } => vec![format!(
                "- Terminal{}{}",
                folder.as_ref().map_or(String::new(), |f| format!(" in {f}")),
                titled(title)
            )],
            Tab::Browser { title } => vec![format!("- Web page{}", titled(title))],
        };
        let next = format!("{text}\n{}", lines.join("\n"));
        if next.len() > PROMPT_BYTE_LIMIT {
            break;
        }
        text = next;
    }
    text
}

/// The completion's parameters without a model (`completionFallbackParams`).
pub fn fallback_params(prompt: &str) -> Value {
    json!({"prompt": prompt, "maxTokens": MAX_TOKENS, "timeoutMs": TIMEOUT_MS})
}

/// The completion's parameters with harness and model (`completionParams`).
pub fn params(prompt: &str) -> Value {
    let mut params = fallback_params(prompt);
    params["harness"] = json!(HARNESS);
    params["model"] = json!(MODEL);
    params
}

fn is_newline_char(c: char) -> bool {
    matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// The name in a model's reply: its first line, without a `Name:` label, quotes, emphasis or
/// closing punctuation, at most [`MAX_WORDS`] words. `None` when nothing is left.
pub fn name_from_reply(reply: &str) -> Option<String> {
    let mut line = reply
        .split(is_newline_char)
        .map(|line| line.trim_matches(is_horizontal_space))
        .find(|line| !line.is_empty())?;
    if let Some((label, rest)) = line.split_once(':')
        && label.to_lowercase() == "name"
    {
        line = rest;
    }
    let line = line
        .trim_matches(|c: char| "\"'`“”‘’*#".contains(c) || is_horizontal_space(c))
        .trim_matches(['.', '!']);
    let joined = line
        .split(char::is_whitespace)
        .filter(|word| !word.is_empty())
        .take(MAX_WORDS)
        .collect::<Vec<_>>()
        .join(" ");
    clean(Some(&joined))
}

/// Why Name from Activity refuses, in the order the action checks (the app shows each one's
/// localized text). `None`: it asks the model.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    /// No workspace, or one the daemon has not keyed yet.
    NoWorkspace,
    /// Its daemon cannot refuse a rename the person made meanwhile.
    OldDaemon,
    /// No tab shows anything to name from.
    NothingToNameFrom,
    /// The agent service is not running.
    NoAgents,
}

/// The facts the action checks before it asks the model.
#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(default)]
pub struct Gate {
    /// A keyed workspace is targeted.
    pub has_workspace: bool,
    /// Its daemon guards the name revision.
    pub guards_revision: bool,
    /// Some tab shows something.
    pub has_activity: bool,
    /// The agent service runs.
    pub has_agents: bool,
}

/// The first refusal `gate` meets.
pub fn refusal(gate: &Gate) -> Option<Refusal> {
    if !gate.has_workspace {
        Some(Refusal::NoWorkspace)
    } else if !gate.guards_revision {
        Some(Refusal::OldDaemon)
    } else if !gate.has_activity {
        Some(Refusal::NothingToNameFrom)
    } else if !gate.has_agents {
        Some(Refusal::NoAgents)
    } else {
        None
    }
}
