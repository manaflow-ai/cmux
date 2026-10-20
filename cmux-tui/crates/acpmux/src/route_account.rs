//! A second account of a subscription CLI (Leo, 2026-10-19: "two Claude, two
//! ChatGPT"). A direct-subscription route may name an account home: the CLI's
//! own config folder for one login (`CLAUDE_CONFIG_DIR` for Claude Code,
//! `CODEX_HOME` for Codex). A chat bound to the route runs its harness with
//! that folder, so it uses that login and no other; the CLI's own
//! `claude auth login` / `codex login` with the same variable signs it in.
//! No token is ever read or stored here: the folder is the CLI's.
use std::collections::BTreeMap;
use std::path::Path;

use crate::routes::{Route, RouteError, RouteFile, RouteKind};

/// The variable that points `family`'s CLI at an account home, if it has one.
pub fn home_var(family: &str) -> Option<&'static str> {
    match family {
        "claude" => Some("CLAUDE_CONFIG_DIR"),
        "codex" => Some("CODEX_HOME"),
        _ => None,
    }
}

/// An account home belongs to a direct-subscription route of exactly one
/// family that has a home variable, and is an absolute path.
pub fn validate(file: &RouteFile) -> Result<(), RouteError> {
    let Some(home) = &file.account_home else { return Ok(()) };
    if file.kind != RouteKind::DirectSubscription {
        return Err(RouteError::BadParams(
            "accountHome is for a direct-subscription route (the CLI's own login)".into(),
        ));
    }
    if !matches!(file.families.as_slice(), [family] if home_var(family).is_some()) {
        return Err(RouteError::BadParams(
            "a route with accountHome serves one family: claude or codex".into(),
        ));
    }
    if !Path::new(home).is_absolute() || home.contains(['\n', '\r', '\0']) || home.len() > 1024 {
        return Err(RouteError::BadParams(format!("accountHome {home:?} is not an absolute path")));
    }
    Ok(())
}

/// Sets the account home of `route` for a spawn of `family`. A route without
/// one leaves the spawn's own `CLAUDE_CONFIG_DIR` / `CODEX_HOME` as it was.
pub fn set_env(route: &Route, family: &str, set: &mut BTreeMap<String, String>) {
    if let (Some(home), Some(var)) = (&route.file.account_home, home_var(family)) {
        set.insert(var.into(), home.clone());
    }
}

/// Creates the account home (owner-only) when a route that names one is
/// written, so the CLI's login finds it: Codex refuses a `CODEX_HOME` that
/// does not exist.
pub fn prepare(file: &RouteFile) -> Result<(), RouteError> {
    let Some(home) = &file.account_home else { return Ok(()) };
    let path = Path::new(home);
    if path.is_dir() {
        return Ok(());
    }
    std::fs::create_dir_all(path).map_err(|e| RouteError::Failed(e.to_string()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))
            .map_err(|e| RouteError::Failed(e.to_string()))?;
    }
    Ok(())
}

/// What a workspace, family or global binding to an account route does to a
/// chat. A chat's conversation is kept in the account home it started in
/// (`claude --resume` and Codex's resume look there), so it never moves to
/// another one by itself.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Inherited {
    /// Not an account route, or the chat's own binding: the route applies.
    Apply,
    /// A new chat: it starts on the account and is bound to it from now on.
    Pin,
    /// A chat that has started: it stays on the login it started with.
    Skip,
}

/// How `route`, bound at `scope` (`chat`, `profile`, `workspace`, `family`,
/// `global`), applies to a chat that has (`started`) or has not begun its
/// conversation.
pub fn inherited(route: &Route, scope: &str, started: bool) -> Inherited {
    if route.file.account_home.is_none() || matches!(scope, "chat" | "profile") {
        Inherited::Apply
    } else if started {
        Inherited::Skip
    } else {
        Inherited::Pin
    }
}

/// The account home a started chat runs in under `route` bound at `scope`:
/// an inherited account route does not apply to it ([`inherited`]).
pub fn effective_home<'a>(route: Option<&'a Route>, scope: &str) -> Option<&'a str> {
    route
        .filter(|_| matches!(scope, "chat" | "profile"))
        .and_then(|r| r.file.account_home.as_deref())
}

/// A started chat may move only between routes of the same account home: its
/// conversation is not in another account's folder.
pub fn switch_allowed(from: Option<&str>, to: Option<&str>) -> Result<(), RouteError> {
    if from == to {
        return Ok(());
    }
    Err(RouteError::BadParams(
        "This chat's conversation belongs to another account. Start a new chat to use this one."
            .into(),
    ))
}
