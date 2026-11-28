//! What a Cloud chat start's failure says to the person, shared by the chat pane (op `cloud_start_pane_surface`,
//! `CloudStartChat.reply`) and any other start that shows it. ask-17e4ae3662, Austin: "We need to be much better at
//! surfacing right errors (ie cloud machine did not start, repo did not clone, claude has no more usage etc) as well
//! as the sign ins."
//!
//! [`surface`] reads the failure's `code` (the CLI's or `CloudMove.Failure`'s) and, for a code that names no cause of
//! its own, its words; it answers [`What`] failed and the [`Next`] step the card offers. `None` for a failure it
//! cannot name, which shows its words as before. [`recover`](crate::recover) decides whether the pane starts again on
//! its own first; this only says what the card shows once it does not.

use serde::{Deserialize, Serialize};

/// What failed, the card's headline.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum What {
    /// The Cloud machine did not start (never came up, or failed at a final stage).
    MachineDidNotStart,
    /// The repository did not clone on the machine.
    RepoDidNotClone,
    /// The chat's folder is not on the machine.
    FolderMissing,
    /// The agent's account is out of usage until its window resets.
    AgentOutOfUsage,
    /// The agent's provider is rate limiting or overloaded right now.
    AgentRateLimited,
    /// The agent on the machine is not signed in to its account.
    AgentNotSignedIn,
    /// The agent's chat did not start on the machine.
    AgentDidNotStart,
    /// This app is signed out of cmux Cloud.
    CloudSignedOut,
    /// This app is signed in to another account than the start's.
    AccountChanged,
    /// The cmux app that runs the start is closed, locked or asleep.
    AppNotConnected,
    /// The account is at its machine cap.
    MachineCap,
    /// The account is at its spend cap.
    SpendCap,
}

/// The step the card offers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Next {
    /// Start again: Retry.
    Retry,
    /// Sign the agent in on the machine.
    AgentSignIn,
    /// Sign in to cmux Cloud.
    CloudSignIn,
    /// Wait for the agent's usage window, or switch agent or account.
    WaitForUsage,
    /// Wait a moment, then Retry.
    WaitThenRetry,
    /// Give the machine access to the repository (the cmux GitHub App), or check its URL, then Retry.
    RepoAccess,
    /// Pick another folder.
    PickFolder,
    /// Open (or unlock) the cmux app.
    OpenApp,
    /// Free a machine, or raise the cap.
    FreeMachine,
    /// Raise the spend cap in billing.
    Billing,
}

/// What the card shows for a failure.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Surfaced {
    pub what: What,
    pub next: Next,
}

const fn shown(what: What, next: Next) -> Option<Surfaced> {
    Some(Surfaced { what, next })
}

/// The failure's [`Surfaced`]: from its code first, then (for a code with no cause of its own) its words.
pub fn surface(code: &str, message: &str) -> Option<Surfaced> {
    use {Next as N, What as W};
    match code {
        "cloud.machine_stuck" | "cloud.start_failed" => {
            return shown(W::MachineDidNotStart, N::Retry);
        }
        "cloud.clone_failed" | "seed.clone_failed" => {
            return shown(W::RepoDidNotClone, N::RepoAccess);
        }
        "cloud.folder_missing" => return shown(W::FolderMissing, N::PickFolder),
        "agent.limit_reached" => return shown(W::AgentOutOfUsage, N::WaitForUsage),
        "cloud.agent_start_failed" | "agent.start_failed" => {
            // The agent's own words often say why: out of usage, or signed out.
            return words(message).or(shown(W::AgentDidNotStart, N::Retry));
        }
        "cloud.signed_out" | "not_signed_in" => return shown(W::CloudSignedOut, N::CloudSignIn),
        "cloud.account_changed" => return shown(W::AccountChanged, N::CloudSignIn),
        "cloud.app_not_connected" => return shown(W::AppNotConnected, N::OpenApp),
        "cloud.machine_cap" => return shown(W::MachineCap, N::FreeMachine),
        "cloud.spend_cap" => return shown(W::SpendCap, N::Billing),
        // The app's own Cloud sign-in is `auth.required`; every other `auth.*` is the agent's.
        "auth.required" => return shown(W::CloudSignedOut, N::CloudSignIn),
        code if code.starts_with("auth.") => return shown(W::AgentNotSignedIn, N::AgentSignIn),
        _ => {}
    }
    words(message)
}

/// The cause the words name, for a code with none: the agent's usage, rate limit or sign-in, a clone, a machine that
/// did not start. Usage comes before rate limits (a usage limit is not over in a moment), and both before sign-in
/// (a rate limit's words can mention authentication).
fn words(message: &str) -> Option<Surfaced> {
    use {Next as N, What as W};
    let text = message.to_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|needle| text.contains(needle));
    if has(&[
        "usage limit",
        "out of usage",
        "hit your limit",
        "reached your limit",
        "limit reached",
        "limit will reset",
        "resets at",
        "credit balance is too low",
        "insufficient_quota",
        "exceeded your current quota",
    ]) {
        return shown(W::AgentOutOfUsage, N::WaitForUsage);
    }
    if has(&["rate limit", "rate_limit", "too many requests", "overloaded", " 429", " 529"]) {
        return shown(W::AgentRateLimited, N::WaitThenRetry);
    }
    if has(&[
        "not logged in",
        "not signed in",
        "please run /login",
        "run /login",
        "login required",
        "claude login",
        "codex login",
        "oauth token has expired",
        "invalid api key",
        "invalid x-api-key",
        "needs a claude login",
        "sign in again",
    ]) {
        return shown(W::AgentNotSignedIn, N::AgentSignIn);
    }
    if has(&[
        "did not clone",
        "could not clone",
        "clone failed",
        "repository not found",
        "fatal: could not read from remote",
    ]) {
        return shown(W::RepoDidNotClone, N::RepoAccess);
    }
    if has(&[
        "machine did not start",
        "machine never came up",
        "did not come up",
        "machine failed to start",
    ]) {
        return shown(W::MachineDidNotStart, N::Retry);
    }
    None
}

#[cfg(test)]
mod tests;
