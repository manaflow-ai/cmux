//! The sr2 launcher for a remote chain: Claude Code itself on the sr2 gateway.
//!
//! `sr2 claude2` (subrouter2) cannot run inside `remote-chain.sb`. Before its
//! `main`, CoreFoundation's initializer asks notifyd for the user's encoding
//! (`getpwuid_r` -> `notify_register_check` -> `bootstrap_look_up3`), a Mach
//! lookup the profile denies, and the reply never comes: the launch sleeps
//! forever with no child (a Mac, 2026-11-28: sr2 16861 and 18931, 80743 and
//! 81030 for 88 minutes). When it gets past that, it writes its account store
//! (`~/.subrouter/codex/claude.json.lock`), which the profile also denies:
//! "operation not permitted". So a remote chain never runs the launcher: it
//! runs what the launcher would, Claude Code on `SUBROUTER2_BASE_URL`, whose
//! gateway picks the pooled account (tailnet identity) and ignores the client
//! token, as `subrouter_plan` does for `sr claude proxy`.

use super::*;

/// The gateway sr2 reaches (its env, the daemon's or the login's).
pub(super) const ROUTE_ENV: &str = "SUBROUTER2_BASE_URL";
/// The placeholder token sr2 gives Claude Code (the gateway ignores it).
const TOKEN: &str = "subrouter2";

/// Whether `argv` starts the sr2 launcher (`sr2 ...`, `claude-sr2`).
pub(super) fn is_sr2(argv: &[String]) -> bool {
    argv.first().is_some_and(|p| crate::sr2_priority::is_sr2_launcher(p))
}

/// The gateway route for `profile`: its own `SUBROUTER2_BASE_URL`, else the
/// daemon's, else the login environment's.
pub(super) fn route(profile: &HarnessProfile) -> Option<String> {
    profile
        .env
        .get(ROUTE_ENV)
        .cloned()
        .or_else(|| std::env::var(ROUTE_ENV).ok())
        .or_else(|| crate::login_env::var(ROUTE_ENV))
        .map(|v| v.trim().to_owned())
        .filter(|v| v.starts_with("http://") || v.starts_with("https://"))
}

/// Whether `word` names sr2's Claude agent: `claude`, or `claude` and an
/// account number (`claude2`).
fn claude_word(word: &str) -> bool {
    word.strip_prefix("claude").is_some_and(|n| n.chars().all(|c| c.is_ascii_digit()))
}

/// The plan for an sr2 `profile` in a remote chain: `claude` (a Claude Code
/// that is not itself a launcher: acpmux's `claude` profile's first word, else
/// `claude` on PATH) with `args` after the launcher's own words, on `route`.
/// Any other sr2 shape (an option of sr2's own, another agent) is refused with
/// the reason, never started.
pub(super) fn sr2_plan(
    profile: &HarnessProfile,
    args: Vec<String>,
    claude: Option<String>,
    route: Option<String>,
) -> Result<(String, Vec<String>, HarnessProfile), String> {
    let launcher_words = profile.argv.get(1..).unwrap_or_default();
    let shape = match launcher_words {
        [] => true,
        [agent] => claude_word(agent),
        _ => false,
    };
    if !shape || !args.starts_with(launcher_words) {
        return Err(format!(
            "the sr2 launcher cannot run in a remote chain's sandbox, and {:?} is not `sr2 claude[N]` that acpmux can run as Claude Code on the sr2 gateway; set this harness to Claude Code with ANTHROPIC_BASE_URL",
            profile.argv.join(" ")
        ));
    }
    let route = route.ok_or(format!(
        "the sr2 launcher cannot run in a remote chain's sandbox (its startup is blocked there), and no sr2 gateway is known to run Claude Code on directly: set {ROUTE_ENV}"
    ))?;
    // A `claude` profile that is itself a launcher (one Mac's is `sr2 claude2`) is not Claude Code.
    let launcher = |p: &str| {
        let base = std::path::Path::new(p).file_name().and_then(|n| n.to_str()).unwrap_or(p);
        crate::sr2_priority::is_sr2_launcher(p) || matches!(base, "sr" | "claude-sr")
    };
    let claude = claude.filter(|c| !launcher(c)).unwrap_or_else(|| "claude".into());
    let args = args.into_iter().skip(launcher_words.len()).collect();
    let mut profile = profile.clone();
    profile.argv = vec![claude.clone()];
    profile.env.remove(ROUTE_ENV);
    profile.env.insert("ANTHROPIC_BASE_URL".into(), route);
    profile.env.insert("ANTHROPIC_AUTH_TOKEN".into(), TOKEN.into());
    Ok((claude, args, profile))
}

#[cfg(test)]
#[path = "remote_sandbox_sr2_tests.rs"]
mod tests;
