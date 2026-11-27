//! The one line cmux adds to Claude Code's own startup banner in a cmux
//! terminal: how this session compacts. Claude Code's banner already shows
//! its version, model, folder and an overridden API base URL; what it cannot
//! know is whether sr2's compaction handling runs around it.
//!
//! The line goes out as the `SessionStart` hook's `systemMessage`, which
//! Claude Code shows to the person and never adds to the model's context.
//! It shows once per process start (`startup` or `resume`), never after a
//! `/clear` or a compaction, and only for a session that compacts
//! differently from stock Claude Code: a launch whose compaction sr2 owns,
//! or a launch on the sr2 gateway that runs without that handling.

/// How the Claude session that ran the hook compacts.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Compaction {
    /// `sr2 claude` launched it: the sr2 supervisor exported
    /// `SR2_CLAUDE2_HOOK_SOCKET`, passed `--autocompact` (380k-420k tokens),
    /// and types `/compact` into this terminal between turns when the
    /// gateway asks for an account rotation, never over a typed draft.
    Managed,
    /// Claude talks to the sr2 gateway (its `ANTHROPIC_BASE_URL`) but no sr2
    /// supervisor runs: it compacts only at its own limit and stays on its
    /// account when that account runs low.
    Unmanaged,
    /// Any other route: stock Claude Code compaction, nothing to say.
    Stock,
}

/// The sr2 supervisor's hook socket variable (`sr claude2`, interactive).
pub(super) const SR2_HOOK_SOCKET_ENV: &str = "SR2_CLAUDE2_HOOK_SOCKET";

/// The local sr2 server's port (`sr2 serve-local`).
const SR2_LOCAL_PORT: &str = ":31416";

/// Classifies a session from its environment: the sr2 hook socket and the
/// API base URL Claude Code runs with.
pub(super) fn compaction(hook_socket: Option<&str>, base_url: Option<&str>) -> Compaction {
    if hook_socket.is_some_and(|socket| !socket.trim().is_empty()) {
        return Compaction::Managed;
    }
    if base_url.is_some_and(is_sr2_gateway) {
        return Compaction::Unmanaged;
    }
    Compaction::Stock
}

/// Whether a base URL names the sr2 gateway (`sr2-gateway.<tailnet>`) or the
/// local sr2 server.
fn is_sr2_gateway(url: &str) -> bool {
    let url = url.trim().to_ascii_lowercase();
    let rest = url.split_once("://").map_or(url.as_str(), |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    host.split('.').next().is_some_and(|label| label.starts_with("sr2-gateway"))
        || host.ends_with(SR2_LOCAL_PORT)
}

/// The line for a `SessionStart` of `source`, or nil when there is none.
pub(super) fn message(compaction: Compaction, source: &str) -> Option<&'static str> {
    if !matches!(source, "startup" | "resume") {
        return None;
    }
    match compaction {
        Compaction::Managed => Some(MANAGED),
        Compaction::Unmanaged => Some(UNMANAGED),
        Compaction::Stock => None,
    }
}

/// The session's own environment, read in the hook (Claude Code passes its
/// environment, settings `env` included, to every hook it runs).
pub(super) fn from_environment() -> Compaction {
    let socket = std::env::var(SR2_HOOK_SOCKET_ENV).ok();
    let base = std::env::var("ANTHROPIC_BASE_URL").ok();
    compaction(socket.as_deref(), base.as_deref())
}

const MANAGED: &str = "cmux: sr2 manages compaction in this session. Claude compacts by about 400k tokens instead of waiting for its limit. When the account nears its usage limit, sr2 types /compact into this terminal between turns (never over a draft you are typing) and the session goes on with a fresh account.";

const UNMANAGED: &str = "cmux: this Claude uses the sr2 gateway without sr2's compaction handling. It compacts only at Claude's own limit and cannot move to a fresh account when this one runs low. Start it with `sr2 claude` to turn that handling on.";

#[cfg(test)]
#[path = "session_banner_tests.rs"]
mod tests;
