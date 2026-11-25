//! An agent account that cannot serve until something changes on the account itself, read from
//! the agent's own error text (cmux#55066): its usage limit is used up until a reset (Claude
//! Code's "You've hit your weekly limit · resets Nov 27, 7am (UTC)", "Claude AI usage limit
//! reached|1764000000"; Codex's "You've hit your usage limit. ... try again at 6:43 PM."), or its
//! provider turned it off ("This organization has been disabled.").
//!
//! Neither is a rate limit a retry outlasts: the turn fails the same way until the reset, so the
//! way on is another agent or another account. `recovery.rs` types such a turn
//! `usage.limit` or `account.disabled` with the sentence below, and the `cmux chat` CLI answers
//! a failed turn with [`sentence`] instead of the agent's bare words. Broader limit words
//! (`turn_errors::is_usage_limit_error`, a 429, "rate limit", a router's quota) are not this:
//! they clear by themselves.

use serde_json::{Map, Value, json};

/// What the account can no longer do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AccountLimitKind {
    /// Out of usage until a reset.
    UsageLimit,
    /// The provider disabled, suspended or banned the account or its organization.
    Disabled,
}

/// One account limit an error names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountLimit {
    pub kind: AccountLimitKind,
    /// The window the agent named ("weekly", "session", "5-hour", "opus"), when it named one.
    pub window: Option<String>,
    /// When it resets, in the agent's own words ("Nov 27, 7am (UTC)", "in 3h", "6:43 PM").
    pub resets: Option<String>,
    /// When it resets, in epoch seconds, where the error gives the time as a number.
    pub resets_at: Option<i64>,
}

/// Words of a used-up account limit, lowercase. "hit your ... limit" is matched on its own below.
const USED_UP: &[&str] = &[
    "usage limit reached",
    "weekly limit reached",
    "session limit reached",
    "reached your usage limit",
    "reached your weekly limit",
    "reached your session limit",
    "out of extra usage",
];

/// Words of an account its provider turned off, lowercase.
const DISABLED: &[&str] = &[
    "organization has been disabled",
    "organization is disabled",
    "account has been disabled",
    "account is disabled",
    "account has been suspended",
    "account is suspended",
    "account has been banned",
    "account has been deactivated",
    "account is deactivated",
];

/// Windows a "hit your <window> limit" may name; any other word is no window.
const WINDOWS: &[&str] =
    &["weekly", "session", "daily", "monthly", "5-hour", "five-hour", "opus", "sonnet", "fable"];

/// The account limit `message` names, or None for any other error (a rate limit included).
pub fn account_limit(message: &str) -> Option<AccountLimit> {
    // ASCII lowercase keeps every byte offset, so a match indexes the original text.
    let lower = message.to_ascii_lowercase();
    if DISABLED.iter().any(|w| lower.contains(w)) {
        return Some(AccountLimit {
            kind: AccountLimitKind::Disabled,
            window: None,
            resets: None,
            resets_at: None,
        });
    }
    let hit = hit_your_limit(&lower);
    if hit.is_none() && !USED_UP.iter().any(|w| lower.contains(w)) {
        return None;
    }
    let window = hit.flatten().or_else(|| {
        WINDOWS
            .iter()
            .find(|w| lower.contains(&format!("{w} limit reached")))
            .map(|w| (*w).to_owned())
    });
    let resets_at = reset_epoch(message);
    Some(AccountLimit {
        kind: AccountLimitKind::UsageLimit,
        window,
        resets: reset_words(message, &lower),
        resets_at,
    })
}

/// "hit your limit" or "hit your <words> limit": Some(window) when it is one, Some(None) for a
/// limit with no window ("usage limit"), None when the words are not there.
fn hit_your_limit(lower: &str) -> Option<Option<String>> {
    for (at, _) in lower.match_indices("hit your ") {
        let rest = &lower[at + "hit your ".len()..];
        // At most three words before "limit": "hit your weekly opus limit".
        let words: Vec<&str> = rest.split_whitespace().take(4).collect();
        let Some(limit) = words.iter().position(|w| w.trim_end_matches(['.', ',', '!']) == "limit")
        else {
            continue;
        };
        let window =
            words[..limit].iter().rev().find(|w| WINDOWS.contains(w)).map(|w| (*w).to_owned());
        // "hit your limit" is; "hit your rate limit" or "hit your token limit" is not an account's allowance.
        // The word right before "limit" names the allowance: "hit your daily rate limit" is a rate limit.
        if limit > 0 && !WINDOWS.contains(&words[limit - 1]) && words[limit - 1] != "usage" {
            continue;
        }
        return Some(window);
    }
    None
}

/// Claude Code's "usage limit reached|<epoch seconds>".
fn reset_epoch(message: &str) -> Option<i64> {
    let (_, after) = message.split_once("limit reached|")?;
    let digits: String = after.chars().take_while(char::is_ascii_digit).collect();
    (digits.len() == 10).then(|| digits.parse().ok()).flatten()
}

/// The reset the error states in words: after "resets " (Claude Code) or "try again at/in "
/// (Codex), to the end of its line or its sentence, without a closing bracket the words did not
/// open.
fn reset_words(message: &str, lower: &str) -> Option<String> {
    let start = ["resets ", "reset at ", "try again at ", "try again in ", "try again after "]
        .iter()
        .filter_map(|w| lower.find(w).map(|at| at + w.len()))
        .min()?;
    let line = message[start..].lines().next().unwrap_or_default();
    let mut depth = 0usize;
    let mut end = line.len();
    for (i, c) in line.char_indices() {
        match c {
            '(' => depth += 1,
            ')' if depth == 0 => {
                end = i;
                break;
            }
            ')' => depth -= 1,
            // A sentence's end: ". " or a trailing period, never the one in "7.30" or "a.m.".
            '.' if line[i + 1..].starts_with(' ') && depth == 0 => {
                end = i;
                break;
            }
            '|' | '"' | '`' => {
                end = i;
                break;
            }
            _ => {}
        }
    }
    let words = line[..end].trim().trim_end_matches(['.', ',', ';']).trim();
    (!words.is_empty() && words.len() <= 80).then(|| words.to_owned())
}

/// The harness's name for a person: `claude-sr` and `claude/claude-opus-5-5` are Claude.
pub fn harness_name(harness: &str) -> String {
    let base = harness.split(['/', '-', '@']).next().unwrap_or(harness);
    match base.to_ascii_lowercase().as_str() {
        "" | "claude" => "Claude".into(),
        "codex" => "Codex".into(),
        "opencode" => "OpenCode".into(),
        "gemini" => "Gemini".into(),
        "pi" => "Pi".into(),
        other => {
            let mut chars = other.chars();
            chars.next().map(|c| c.to_uppercase().chain(chars).collect()).unwrap_or_default()
        }
    }
}

/// The agent to suggest instead of `harness`: Codex for Claude and the rest, Claude for Codex.
pub fn other_agent(harness: &str) -> &'static str {
    if harness_name(harness) == "Codex" { "claude" } else { "codex" }
}

impl AccountLimit {
    /// The `errorKind` (`recovery::kind`).
    pub fn error_kind(&self) -> &'static str {
        match self.kind {
            AccountLimitKind::UsageLimit => crate::recovery::kind::USAGE_LIMIT,
            AccountLimitKind::Disabled => crate::recovery::kind::ACCOUNT_DISABLED,
        }
    }

    /// The `details` keys of a typed error: `limitWindow`, `resets`, `resetsAt`.
    pub fn details(&self) -> Map<String, Value> {
        let mut out = Map::new();
        if let Some(window) = &self.window {
            out.insert("limitWindow".into(), json!(window));
        }
        if let Some(resets) = &self.resets {
            out.insert("resets".into(), json!(resets));
        }
        if let Some(at) = self.resets_at {
            out.insert("resetsAt".into(), json!(at));
        }
        out
    }

    /// What happened, in one sentence: "Claude's account hit its weekly usage limit; it resets
    /// Nov 27, 7am (UTC)." `harness` is the harness id or name (None: "The agent").
    pub fn what_happened(&self, harness: Option<&str>) -> String {
        let who = match harness {
            Some(h) => format!("{}'s account", harness_name(h)),
            None => "The agent's account".to_owned(),
        };
        match self.kind {
            AccountLimitKind::Disabled => {
                format!("{who} was turned off by its provider (disabled or suspended).")
            }
            AccountLimitKind::UsageLimit => {
                let window = self.window.as_deref().map(|w| format!("{w} ")).unwrap_or_default();
                let when = match (&self.resets, self.resets_at) {
                    (Some(words), _) => format!("; it resets {words}"),
                    (None, Some(at)) => {
                        format!("; it resets at {}", crate::clock_text::iso(at as u64 * 1000))
                    }
                    (None, None) => String::new(),
                };
                format!("{who} hit its {window}usage limit{when}.")
            }
        }
    }

    /// What to do, in one sentence, naming the other agent and the sign-in.
    pub fn what_to_do(&self, harness: Option<&str>) -> String {
        let name = harness.map(harness_name).unwrap_or_else(|| "the agent".to_owned());
        // With no harness named there is no agent to suggest: it may be the one the account is on.
        let such_as = harness
            .map(|h| format!(" (such as {})", harness_name(other_agent(h))))
            .unwrap_or_default();
        let wait = match self.kind {
            AccountLimitKind::UsageLimit => " or wait for the reset",
            AccountLimitKind::Disabled => "",
        };
        format!(
            "Retrying fails the same way: switch the chat to another agent{such_as}, or \
             sign {name} in with another account{wait}, then send the message again."
        )
    }

    /// Both sentences.
    pub fn sentence(&self, harness: Option<&str>) -> String {
        format!("{} {}", self.what_happened(harness), self.what_to_do(harness))
    }
}

/// [`AccountLimit::sentence`] for `message`, or None when it names no account limit.
pub fn sentence(message: &str, harness: Option<&str>) -> Option<String> {
    account_limit(message).map(|limit| limit.sentence(harness))
}
