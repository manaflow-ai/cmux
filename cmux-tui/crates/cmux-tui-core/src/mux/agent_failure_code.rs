//! Stable failure codes for a failed agent turn.
//!
//! A turn's `errorText` is a provider's own wording. The notice names the class instead
//! ("Mango hit a rate limit"), keeps the text in its body, and folds the chats that hit
//! the same class together (`agent_chat_notices.rs`). The strings of [`FailureCode::code`]
//! are stable: tools and people group by them, so a code is never renamed or reused.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// Chats failing with one code within this window are one notice.
pub(crate) const FOLD_WINDOW: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum FailureCode {
    RateLimit,
    AuthExpired,
    ContextFull,
    Network,
    AgentCrashed,
    ToolError,
    Other,
}

impl FailureCode {
    /// The stable code. Never change a value.
    pub(crate) fn code(self) -> &'static str {
        match self {
            Self::RateLimit => "rate_limit",
            Self::AuthExpired => "auth_expired",
            Self::ContextFull => "context_full",
            Self::Network => "network",
            Self::AgentCrashed => "agent_crashed",
            Self::ToolError => "tool_error",
            Self::Other => "other",
        }
    }

    /// What the title says after a name: "Mango hit a rate limit".
    pub(crate) fn headline(self) -> &'static str {
        match self {
            Self::RateLimit => "hit a rate limit",
            Self::AuthExpired => "needs you to sign in again",
            Self::ContextFull => "ran out of context",
            Self::Network => "lost the network",
            Self::AgentCrashed => "crashed",
            Self::ToolError => "hit a tool error",
            Self::Other => "failed",
        }
    }

    /// What the title says after a count: "5 chats hit a rate limit".
    pub(crate) fn plural_headline(self) -> &'static str {
        match self {
            Self::RateLimit => "hit a rate limit",
            Self::AuthExpired => "need you to sign in again",
            Self::ContextFull => "ran out of context",
            Self::Network => "lost the network",
            Self::AgentCrashed => "crashed",
            Self::ToolError => "hit a tool error",
            Self::Other => "failed",
        }
    }

    /// Whether failures of this code fold across chats. `Other` says nothing in common.
    pub(crate) fn groups(self) -> bool {
        self != Self::Other
    }
}

/// `text` holds the number `code` as a whole number ("HTTP 429", not "14290").
fn has_status(text: &str, code: &str) -> bool {
    text.match_indices(code).any(|(at, _)| {
        let before = text[..at].chars().next_back();
        let after = text[at + code.len()..].chars().next();
        !before.is_some_and(|c| c.is_ascii_digit()) && !after.is_some_and(|c| c.is_ascii_digit())
    })
}

/// The class of a failed turn's error text (Claude and Codex wording, and the network's).
pub(crate) fn failure_code(error_text: &str) -> FailureCode {
    let text = error_text.to_ascii_lowercase();
    let any = |needles: &[&str]| needles.iter().any(|needle| text.contains(needle));
    // Context first: "prompt is too long" can ride in an HTTP 400 or 413 body.
    if any(&[
        "prompt is too long",
        "context length",
        "context window",
        "context_length_exceeded",
        "maximum context",
        "context is full",
        "too many tokens",
        "input is too long",
    ]) {
        return FailureCode::ContextFull;
    }
    if any(&[
        "please run /login",
        "run /login",
        "invalid api key",
        "invalid x-api-key",
        "authentication_error",
        "authentication failed",
        "unauthorized",
        "token expired",
        "expired token",
        "login expired",
        "not logged in",
        "sign in again",
        "log in again",
        "oauth token has expired",
        "refresh token",
    ]) || has_status(&text, "401")
    {
        return FailureCode::AuthExpired;
    }
    if any(&[
        "rate limit",
        "rate_limit",
        "ratelimit",
        "usage limit",
        "overloaded",
        "too many requests",
        "quota",
        "limit reached",
        "capacity",
    ]) || has_status(&text, "429")
        || has_status(&text, "529")
    {
        return FailureCode::RateLimit;
    }
    if any(&[
        "econnreset",
        "econnrefused",
        "etimedout",
        "enotfound",
        "eai_again",
        "network",
        "connection reset",
        "connection refused",
        "connection closed",
        "timed out",
        "dns",
        "socket hang up",
        "stream disconnected",
        "error sending request",
        "offline",
    ]) {
        return FailureCode::Network;
    }
    if any(&[
        "process exited",
        "exited unexpectedly",
        "exited with code",
        "agent crashed",
        "panicked",
        "segmentation fault",
        "sigkill",
        "sigsegv",
        "broken pipe",
        "agent process",
    ]) {
        return FailureCode::AgentCrashed;
    }
    if any(&["tool call failed", "tool failed", "tool error", "tool_use_error", "mcp error"]) {
        return FailureCode::ToolError;
    }
    FailureCode::Other
}

/// What one failed turn's notice does, given the failures of its code before it.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Fold {
    /// Post the chat's own notice (the first of its code in the window, or an ungrouped code).
    Own,
    /// The second chat: post the group notice, "2 chats hit a rate limit".
    Group { window: u64, count: u32 },
    /// The group notice is up: count this chat in it and post nothing.
    Silent,
}

/// The failures of the last window, by code. Memory only.
#[derive(Default)]
pub(crate) struct FailureFolds {
    open: HashMap<FailureCode, Window>,
    windows: u64,
}

struct Window {
    since: Instant,
    count: u32,
}

impl FailureFolds {
    pub(crate) fn admit(&mut self, code: FailureCode, now: Instant) -> Fold {
        if !code.groups() {
            return Fold::Own;
        }
        if let Some(window) = self.open.get_mut(&code)
            && now.saturating_duration_since(window.since) < FOLD_WINDOW
        {
            window.count += 1;
            return if window.count == 2 {
                Fold::Group { window: self.windows, count: 2 }
            } else {
                Fold::Silent
            };
        }
        self.windows += 1;
        self.open.insert(code, Window { since: now, count: 1 });
        Fold::Own
    }
}

#[cfg(test)]
#[path = "agent_failure_code_tests.rs"]
mod tests;
