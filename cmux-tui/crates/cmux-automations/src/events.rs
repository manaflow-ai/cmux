//! Named events: "when an agent goes idle", "when a pull request is opened".
//!
//! An event trigger (`--when agent-idle`) is a `watch` whose command cmux
//! supplies: the runner keeps `cmux automation events NAME` alive, and every
//! line it prints is one event, through the same debounce, condition and
//! guardrails as any `--watch`. The vocabulary is this table, so adding an
//! event is one row here plus its source in the CLI
//! (`cli/automation/events.rs`).

/// One event an automation can start on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EventKind {
    /// The `--when` word: `agent-idle`.
    pub name: &'static str,
    /// How the GUI and `show` say the trigger: "When an agent goes idle".
    pub label: &'static str,
    /// One line for `cmux automation events`.
    pub summary: &'static str,
    /// Where the event comes from and how late it can be, said plainly.
    pub source: &'static str,
    /// Lines closer together than this are one event.
    pub debounce_seconds: u64,
    /// The guardrails a new automation on this event gets unless flags say otherwise.
    pub cooldown_seconds: u64,
    pub max_runs_per_day: Option<u32>,
    /// What `cmux automation test` feeds the condition and the prompt when no
    /// `--event` is given: one line the source would print.
    pub sample: &'static str,
}

/// Every event, in the order `cmux automation events` lists them.
pub const EVENTS: &[EventKind] = &[
    EventKind {
        name: "agent-idle",
        label: "When an agent goes idle",
        summary: "an agent in a terminal or an agent chat finishes its turn and waits",
        source: "pushed by the cmux daemon for terminal agents; agent chats are read from the \
                 cmux app once a second, so a run starts within a few seconds",
        debounce_seconds: 5,
        cooldown_seconds: 60,
        max_runs_per_day: Some(48),
        sample: r#"{"event":"agent-idle","kind":"agent","change":"state","id":"tab_1","source":"chat","state":"idle","agent_session":"fix-login"}"#,
    },
    EventKind {
        name: "agent-needs-input",
        label: "When an agent needs input",
        summary: "an agent asks a question or waits on a permission prompt",
        source: "pushed by the cmux daemon for terminal agents; agent chats and permission \
                 prompts are read from the cmux app once a second",
        debounce_seconds: 5,
        cooldown_seconds: 60,
        max_runs_per_day: Some(48),
        sample: r#"{"event":"agent-needs-input","kind":"dialog","change":"opened","id":"req_1","dialog_kind":"permissionRequest"}"#,
    },
    EventKind {
        name: "pr-opened",
        label: "When a pull request is opened",
        summary: "you, or an agent signed in as you, open a pull request on GitHub",
        source: "nothing pushes GitHub changes to cmux yet: read through `gh` (signed in) every \
                 5 minutes, the GitHub pull requests signal's own pace, so a run starts up to \
                 5 minutes after the pull request opens",
        debounce_seconds: 5,
        cooldown_seconds: 0,
        max_runs_per_day: Some(24),
        sample: r#"{"event":"pr-opened","url":"https://github.com/octo/app/pull/7","repo":"octo/app","number":7,"title":"Fix the login redirect","draft":false}"#,
    },
];

/// The event named `name`.
pub fn find(name: &str) -> Option<&'static EventKind> {
    EVENTS.iter().find(|e| e.name == name)
}

/// The names, joined for an error or a help line: `agent-idle, agent-needs-input, pr-opened`.
pub fn names() -> String {
    EVENTS.iter().map(|e| e.name).collect::<Vec<_>>().join(", ")
}

/// The watch command the runner keeps alive for `name`: `cmux automation
/// events NAME` through `program` (the runner's own binary), quoted for `/bin/sh -c`.
pub fn watch_command(program: &str, name: &str) -> String {
    format!("{} automation events {}", sh_quote(program), sh_quote(name))
}

fn sh_quote(word: &str) -> String {
    if !word.is_empty()
        && word.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_./:@+".contains(&b))
    {
        return word.to_string();
    }
    format!("'{}'", word.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests;
