//! Everything one Feed row says, as values (Swift `FeedRowContent` and
//! `FeedPlace`): what happened, one line of detail, who did it, where, its
//! icon and marks. The page renders these; it never re-derives them.

use serde::Serialize;

use super::item::{FeedItem, Priority, State};
use super::prompt::{ApproveType, Prompt};

/// Where an item happened, in the person's words: the agent, the
/// workspace and the tab, by name. Items carry only ids, so the daemon
/// resolves them against its own store; nil parts fall back to what the
/// poster declared.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Place {
    /// The agent or harness ("Claude Code", a named chat session).
    pub agent: Option<String>,
    pub workspace: Option<String>,
    pub tab: Option<String>,
}

impl Place {
    /// A place whose agent is a harness id (`claude`), named as products are named.
    pub fn with_harness(
        harness: Option<&str>,
        workspace: Option<String>,
        tab: Option<String>,
    ) -> Self {
        Self { agent: harness.map(agent_name), workspace, tab }
    }
}

/// Product names stay in English.
pub fn agent_name(harness: &str) -> String {
    match harness {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "opencode" => "OpenCode",
        "gemini" => "Gemini CLI",
        "cursor" => "Cursor",
        "pi" => "Pi",
        other => other,
    }
    .to_owned()
}

/// `row` of a view item (feed-page.md section 2).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Row {
    /// What happened: "Allow rm -rf build?", "Finished: updated FeedModel.swift".
    pub headline: String,
    /// One line of concrete detail: the command, the question, the first
    /// line of the body.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// The detail is code (a command): drawn monospaced.
    pub detail_is_code: bool,
    /// The agent or poster: "Claude Code".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub who: Option<String>,
    /// "api-server › Fix login redirect".
    #[serde(rename = "where", skip_serializing_if = "Option::is_none")]
    pub place: Option<String>,
    /// The icon registry name the page draws (`terminal`, `agent.question`, ...).
    pub icon: &'static str,
    pub urgent: bool,
    pub dimmed: bool,
    pub local: bool,
}

fn non_empty(text: &str) -> Option<&str> {
    let trimmed = text.trim();
    (!trimmed.is_empty()).then_some(trimmed)
}

/// The first line with text.
fn first_line(text: &str) -> &str {
    text.lines().map(str::trim).find(|line| !line.is_empty()).unwrap_or_default()
}

/// Without Markdown's emphasis and code marks, so a one-line detail reads as text.
fn plain(text: &str) -> String {
    let mut text = text.replace("**", "").replace("__", "").replace('`', "");
    if text.starts_with('#') {
        text = text.trim_start_matches('#').trim().to_owned();
    }
    text
}

fn contains_folded(haystack: &str, needle: &str) -> bool {
    haystack.to_lowercase().contains(&needle.to_lowercase())
}

impl Row {
    pub fn of(item: &FeedItem, place: Option<&Place>) -> Self {
        let prompt = Prompt::parse(&item.kind, &item.prompt);
        let (headline, detail, detail_is_code) = lines(item, &prompt);
        let who = who(item, place);
        let place = place_text(item, place, &who);
        Self {
            headline,
            detail: (!detail.is_empty()).then_some(detail),
            detail_is_code,
            who: (!who.is_empty()).then_some(who),
            place: (!place.is_empty()).then_some(place),
            icon: icon(item, &prompt),
            urgent: item.is_open_request() && item.priority >= Priority::High,
            dimmed: matches!(item.state, State::Expired | State::Cancelled),
            local: item.is_local(),
        }
    }
}

/// What happened and its one line of detail, from the item alone.
fn lines(item: &FeedItem, prompt: &Prompt) -> (String, String, bool) {
    let (detail, is_code) = detail(item, prompt);
    let title = item.title.trim();
    // A title that only names its poster ("GitHub", "Agent") says nothing: the detail leads.
    let generic = title.is_empty()
        || title == item.poster.label
        || item.poster.harness.as_deref() == Some(title);
    let headline = if generic && !detail.is_empty() { detail.clone() } else { title.to_owned() };
    // A detail the headline already says ("Asked: Which branch…" over "Which branch…") is left out.
    let shown = if generic || detail.is_empty() || contains_folded(title, &detail) {
        String::new()
    } else {
        detail
    };
    (headline, shown, !generic && is_code)
}

fn detail(item: &FeedItem, prompt: &Prompt) -> (String, bool) {
    let body = || plain(first_line(&item.body));
    match prompt {
        Prompt::Approve { command, summary, .. } => {
            if let Some(command) = command.as_deref().and_then(|c| non_empty(first_line(c))) {
                return (command.to_owned(), true);
            }
            let summary = first_line(summary);
            (if summary.is_empty() { body() } else { summary.to_owned() }, false)
        }
        Prompt::Question { question } => (plain(first_line(question)), false),
        Prompt::Choice { questions } => {
            (plain(first_line(questions.first().map_or("", |q| q.question.as_str()))), false)
        }
        Prompt::Confirm { statement } => (plain(first_line(statement)), false),
        Prompt::SignIn { origin } => (origin.replace("https://", ""), false),
        Prompt::Passkey { origin, rp_id } => {
            (rp_id.as_deref().unwrap_or(origin).replace("https://", ""), false)
        }
        Prompt::File { purpose } => (plain(first_line(purpose)), false),
        Prompt::Handoff { reason, resume_hint } => {
            (plain(first_line(resume_hint.as_deref().unwrap_or(reason))), false)
        }
        Prompt::Notice | Prompt::Review { .. } | Prompt::Input | Prompt::Custom => (body(), false),
    }
}

fn who(item: &FeedItem, place: Option<&Place>) -> String {
    if let Some(agent) = place.and_then(|p| p.agent.as_deref()).and_then(non_empty) {
        return agent.to_owned();
    }
    if let Some(harness) = item.poster.harness.as_deref().and_then(non_empty) {
        return harness.to_owned();
    }
    // The permission bridge's placeholder label names nobody.
    let label = item.poster.label.trim();
    match item.poster.kind.as_str() {
        "agent" | "harness" if label.eq_ignore_ascii_case("agent") => String::new(),
        _ => label.to_owned(),
    }
}

/// The resolved workspace and tab; else what the poster declared (a hook
/// posts its folder as its label), never an opaque id.
fn place_text(item: &FeedItem, place: Option<&Place>, who: &str) -> String {
    let parts: Vec<&str> = place
        .map(|p| [p.workspace.as_deref(), p.tab.as_deref()])
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(non_empty)
        .collect();
    if !parts.is_empty() {
        return parts.join(" › ");
    }
    let label = item.poster.label.trim();
    let harness = item.poster.harness.as_deref().and_then(non_empty);
    if label.is_empty() || label == who || harness.is_none() || label.eq_ignore_ascii_case("agent")
    {
        return String::new();
    }
    label.to_owned()
}

/// The icon registry name of an item (the dotted names `webviews` draws, as the Swift `IconName`
/// cases did: `agent.question`, `feed.choice`).
pub fn icon(item: &FeedItem, prompt: &Prompt) -> &'static str {
    match prompt {
        Prompt::Notice => match item.poster.kind.as_str() {
            "integration" => "integration",
            "server" | "vm" => "machine.remote",
            "automation" => "automation",
            "system" if item.context_str("terminal").is_some() => "terminal",
            _ => "notification",
        },
        Prompt::Approve { action, .. } => match action {
            ApproveType::Command => "terminal",
            ApproveType::Edit => "action.edit",
            ApproveType::Network => "network",
            ApproveType::Install => "package",
            ApproveType::Tool | ApproveType::Custom => "tools",
        },
        Prompt::Question { .. } => "agent.question",
        Prompt::Choice { .. } => "feed.choice",
        Prompt::Confirm { .. } => "action.confirm",
        Prompt::SignIn { .. } => "account.signin",
        Prompt::Passkey { .. } => "account.passkey",
        Prompt::Review { .. } => "action.review",
        Prompt::Input => "feed.input",
        Prompt::File { .. } => "file.new",
        Prompt::Handoff { .. } => "agent.handoff",
        Prompt::Custom => "feed.custom",
    }
}
