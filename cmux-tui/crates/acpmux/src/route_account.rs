//! A second account of a subscription CLI (Leo, 2026-10-19: "two Claude, two
//! ChatGPT"). A direct-subscription route may name an account home: the CLI's
//! own config folder for one login (`CLAUDE_CONFIG_DIR` for Claude Code,
//! `CODEX_HOME` for Codex). A chat bound to the route runs its harness with
//! that folder, so it uses that login and no other; the CLI's own
//! `claude auth login` / `codex login` with the same variable signs it in.
//! No token is ever read or stored here: the folder is the CLI's.
//!
//! A chat's conversation is kept in the home it started in (`claude --resume`
//! and Codex's resume look there), so a new chat records that home as its
//! store ([`record`]) and never leaves it: a later route, default change,
//! fallback, fork or aside keeps the folder ([`keep_home`]).
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::routes::{Route, RouteError, RouteFile, RouteKind};
use crate::store::SessionMeta;

/// The variable that points `family`'s CLI at an account home, if it has one.
pub fn home_var(family: &str) -> Option<&'static str> {
    match family {
        "claude" => Some("CLAUDE_CONFIG_DIR"),
        "codex" => Some("CODEX_HOME"),
        _ => None,
    }
}

/// `accountHome` of a route/add request: absent or null is none; anything
/// else must be a path ([`validate`]), never an empty or non-string value
/// that would quietly mean the default login.
pub fn from_json(params: &serde_json::Value) -> Result<Option<String>, RouteError> {
    match params.get("accountHome") {
        None | Some(serde_json::Value::Null) => Ok(None),
        Some(serde_json::Value::String(home)) if !home.is_empty() => Ok(Some(home.clone())),
        Some(other) => {
            Err(RouteError::BadParams(format!("accountHome {other} is not an absolute path")))
        }
    }
}

/// An account home belongs to a direct-subscription route of exactly one
/// family that has a home variable, and is an absolute path that is never
/// expanded at spawn (no `${…}`).
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
    if !Path::new(home).is_absolute()
        || home.contains(['\n', '\r', '\0'])
        || home.contains("${")
        || home.len() > 1024
    {
        return Err(RouteError::BadParams(format!("accountHome {home:?} is not an absolute path")));
    }
    // The CLI's own folder is its default login, never a second account.
    let default = [".claude", ".codex"].map(|d| dirs::home_dir().map(|h| h.join(d)));
    if default.iter().flatten().any(|d| d == Path::new(home)) {
        return Err(RouteError::BadParams(format!(
            "accountHome {home:?} is the CLI's own folder; pick a new folder for another account"
        )));
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

/// Whether `meta`'s conversation already has a home: the chat has started,
/// or it runs on a recorded store (an adopted chat, a fork of an account
/// chat). Such a chat keeps its folder whatever route it runs on.
pub fn has_home(meta: &SessionMeta) -> bool {
    meta.agent_session_id.is_some() || meta.chat_store.is_some()
}

/// Puts `family`'s home variable back to `before`, its value ahead of the
/// route, for a chat whose conversation already has a home ([`has_home`]).
/// The route's other variables still apply.
pub fn keep_home(family: &str, before: Option<String>, env: &mut BTreeMap<String, String>) {
    let Some(var) = home_var(family) else { return };
    match before {
        Some(value) => env.insert(var.to_owned(), value),
        None => env.remove(var),
    };
}

/// Records the account home a new chat started in as its store, once its
/// conversation exists: every later spawn, fork and aside then runs in that
/// folder (`SessionMeta::apply_chat_store`), whatever its route is by then.
/// A spawn that failed records nothing.
pub fn record(meta: &mut SessionMeta, home: Option<&Path>) -> bool {
    match home {
        Some(home) if meta.agent_session_id.is_some() && meta.chat_store.is_none() => {
            meta.chat_store = Some(home.to_path_buf());
            true
        }
        _ => false,
    }
}

/// `meta`'s env as its spawn builds it from `harness_env` (`Hub::harness_env`: profile, preset
/// and chat store): each value expanded (`~/work`, `${home}/work`), then the chat's own env
/// over it, unexpanded (`hub/spawn.rs`). Before its route.
pub fn spawn_env(
    meta: &SessionMeta,
    mut harness_env: BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let home = dirs::home_dir().unwrap_or_default();
    let model = meta.model_request.clone().unwrap_or_default();
    for value in harness_env.values_mut() {
        *value = crate::hub::expand_env_value(value, &meta.cwd, &home, &model);
    }
    harness_env.extend(meta.session_env.clone());
    harness_env
}

/// The folder `meta`'s conversation is kept in when it is not the CLI's
/// default: its recorded store, else its own or its harness env's variable
/// (profile and preset, `Hub::harness_env`).
pub fn current_home(
    meta: &SessionMeta,
    family: &str,
    harness_env: &BTreeMap<String, String>,
) -> Option<PathBuf> {
    let var = home_var(family)?;
    let mut env = harness_env.clone();
    // Expanded as at spawn (`~/work`, `${home}/work`): the folder it runs in.
    let home = dirs::home_dir().unwrap_or_default();
    let model = meta.model_request.clone().unwrap_or_default();
    for value in env.values_mut() {
        *value = crate::hub::expand_env_value(value, &meta.cwd, &home, &model);
    }
    env.extend(meta.session_env.clone());
    meta.apply_chat_store(&mut env);
    env.get(var).map(PathBuf::from)
}

/// A chat whose conversation has a home may move to a route with no account
/// home (its folder stays) or with that same home, never to another one.
pub fn switch_allowed(current: Option<&Path>, to: &Route) -> Result<(), RouteError> {
    match to.file.account_home.as_deref().map(Path::new) {
        Some(home) if Some(home) != current => Err(RouteError::BadParams(
            "This chat's conversation belongs to another account. Start a new chat to use this one."
                .into(),
        )),
        _ => Ok(()),
    }
}
