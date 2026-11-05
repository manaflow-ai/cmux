//! `_acpmux/accounts` and `_acpmux/account/set`: the subscription logins a
//! chat can run on, each with its sign-in, plan and whether routing may move a
//! chat onto it (Leo, 2026-11-05: "we have code router, but we don't have the
//! codex signed account, like auto routing permission", and T3 Code's
//! Providers page: "Authenticated · ChatGPT Pro Subscription").
//!
//! An account is the Codex CLI's own login (`codex-login`, built in), the
//! Claude Code login (`claude-login`, listed only), a direct-subscription
//! route with an account home, or a direct API-key route (`key`: its key is
//! a reference, never resolved here). Each says whether it is its family's
//! `default`: the family binding (`_acpmux/route/default.set`
//! `family:<family>`), else the global one, else the CLI's own login. The
//! plan and email come from the login's own
//! files and are only read here: no token leaves this module. Settings shows
//! them, so only the unix socket and the local app may ask; `set` writes a
//! route file, so only the unix socket.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use base64::Engine as _;
use serde_json::{Value, json};

use super::Origin;
use crate::hub::Hub;
use crate::routes::{self, Route, RouteKind};
use crate::rpc::{RpcError, method};

/// The listed id of the Claude Code CLI's own login (not a route).
const CLAUDE_LOGIN_ID: &str = "claude-login";

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "accounts are read only from the local app or the unix socket",
        ));
    }
    let (dir, state) = routes::places(&*hub.config.read().await);
    match m {
        method::MUX_ACCOUNTS => {
            let family = params.get("family").and_then(Value::as_str).map(str::to_owned);
            tokio::task::spawn_blocking(move || {
                let list = list(dir.as_deref(), &routes::bindings(&state))
                    .into_iter()
                    .filter(|a| family.as_deref().is_none_or(|f| a["family"] == f))
                    .collect::<Vec<_>>();
                json!({"accounts": list})
            })
            .await
            .map_err(|e| RpcError::internal(e.to_string()))
        }
        _ => {
            if origin != Origin::Local {
                return Err(RpcError::invalid_params(
                    "turning an account on or off changes where chats go: only the unix socket may ask",
                ));
            }
            let id = params
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("id is required"))?
                .to_owned();
            let enabled = params.get("enabled").and_then(Value::as_bool);
            let name = params.get("name").and_then(Value::as_str).map(str::to_owned);
            tokio::task::spawn_blocking(move || set(dir.as_deref(), &id, enabled, name))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?
        }
    }
}

/// Every account: the Codex CLI's own login first, then the account routes by
/// id, then the Claude Code login, each with whether it is its family's default.
fn list(dir: Option<&Path>, bindings: &routes::Bindings) -> Vec<Value> {
    let mut out = listed(dir);
    for account in &mut out {
        let family = account["family"].as_str().unwrap_or_default().to_owned();
        let id = account["id"].as_str().unwrap_or_default().to_owned();
        let builtin = account["builtin"].as_bool().unwrap_or(false);
        account["default"] = json!(is_default(bindings, &family, &id, builtin));
    }
    out
}

/// Whether account `id` of `family` is the one a new chat of that family runs
/// on: the family binding, else the global one, else the CLI's own login.
fn is_default(bindings: &routes::Bindings, family: &str, id: &str, builtin: bool) -> bool {
    match bindings.families.get(family).or(bindings.global.as_ref()) {
        Some(bound) => bound == id,
        None => builtin,
    }
}

fn listed(dir: Option<&Path>) -> Vec<Value> {
    let mut out = Vec::new();
    if let Ok(builtin) = routes::find(dir, routes::CODEX_LOGIN_ROUTE_ID) {
        let home = builtin.file.account_home.clone().map(PathBuf::from);
        let folder = home.clone().or_else(crate::route_shadow::codex_base);
        out.push(view(&builtin, "codex", home.as_deref(), folder.as_deref(), true));
    }
    for route in routes::load(dir).0 {
        let family = match route.file.families.as_slice() {
            [f] if f == "codex" || f == "claude" => f.clone(),
            _ => continue,
        };
        if route.id == routes::CODEX_LOGIN_ROUTE_ID {
            continue;
        }
        if route.file.kind == RouteKind::DirectApiKey {
            out.push(key_view(&route, &family));
            continue;
        }
        if route.file.kind != RouteKind::DirectSubscription {
            continue;
        }
        let Some(home) = route.file.account_home.clone().map(PathBuf::from) else { continue };
        out.push(view(&route, &family, Some(&home), Some(&home), false));
    }
    let claude = claude_login(None);
    out.push(json!({
        "id": CLAUDE_LOGIN_ID, "family": "claude", "name": "Claude Code login", "home": null,
        "shadowOf": null, "signedIn": claude.signed_in, "plan": claude.plan,
        "email": claude.email, "enabled": true, "builtin": true,
    }));
    out
}

/// An API-key route: signed in by its key reference, which is never resolved
/// here (a `keychain:` one would ask the keychain).
fn key_view(route: &Route, family: &str) -> Value {
    json!({
        "id": route.id, "family": family, "name": route.name(), "home": null,
        "shadowOf": null, "signedIn": route.file.secret.is_some(), "plan": null,
        "email": null, "enabled": !route.file.disabled, "builtin": false, "key": true,
    })
}

fn view(
    route: &Route,
    family: &str,
    home: Option<&Path>,
    folder: Option<&Path>,
    builtin: bool,
) -> Value {
    let login = match family {
        "codex" => folder.map(codex_login).unwrap_or_default(),
        _ => claude_login(folder),
    };
    json!({
        "id": route.id,
        "family": family,
        "name": route.name(),
        "home": home,
        "shadowOf": route.file.shadow_of,
        "signedIn": login.signed_in,
        "plan": login.plan,
        "email": login.email,
        "enabled": !route.file.disabled,
        "builtin": builtin,
    })
}

/// Turns an account on or off, or renames it. The built-in Codex login is
/// written as a route file of its id, which replaces the built-in one.
fn set(
    dir: Option<&Path>,
    id: &str,
    enabled: Option<bool>,
    name: Option<String>,
) -> Result<Value, RpcError> {
    let error = |e: routes::RouteError| crate::hub::route_error(&e);
    let route = routes::find(dir, id).map_err(error)?;
    let key = route.file.kind == RouteKind::DirectApiKey;
    if !key
        && (route.file.kind != RouteKind::DirectSubscription
            || (id != routes::CODEX_LOGIN_ROUTE_ID && route.file.account_home.is_none()))
    {
        return Err(RpcError::invalid_params(format!("{id} is not an account")));
    }
    let mut file = route.file.clone();
    if let Some(enabled) = enabled {
        file.disabled = !enabled;
    }
    if let Some(name) = name.filter(|n| !n.trim().is_empty()) {
        file.name = Some(name.trim().to_owned());
    }
    let written = routes::add(dir, id, &file, true).map_err(error)?;
    let family = file.families.first().cloned().unwrap_or_else(|| "codex".into());
    if key {
        return Ok(key_view(&written, &family));
    }
    let home = written.file.account_home.clone().map(PathBuf::from);
    let folder = home.clone().or_else(crate::route_shadow::codex_base);
    Ok(view(
        &written,
        &family,
        home.as_deref(),
        folder.as_deref(),
        id == routes::CODEX_LOGIN_ROUTE_ID,
    ))
}

#[derive(Default)]
struct Login {
    signed_in: bool,
    plan: Option<String>,
    email: Option<String>,
}

/// A Codex login folder's sign-in: its `auth.json`, and the plan and email
/// its id token names.
fn codex_login(folder: &Path) -> Login {
    let Ok(text) = std::fs::read_to_string(folder.join("auth.json")) else {
        return Login::default();
    };
    let auth: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    let claims = auth
        .pointer("/tokens/id_token")
        .and_then(Value::as_str)
        .and_then(|jwt| jwt.split('.').nth(1))
        .and_then(|payload| {
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(payload.trim_end_matches('='))
                .ok()
        })
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .unwrap_or(Value::Null);
    let text_at = |v: &Value, pointer: &str| {
        v.pointer(pointer).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    Login {
        signed_in: crate::agent_login::signed_in_at(crate::agent_login::Agent::Codex, folder),
        plan: text_at(&claims, "/https:~1~1api.openai.com~1auth/chatgpt_plan_type"),
        email: text_at(&claims, "/email"),
    }
}

/// A Claude Code login in `folder` (`CLAUDE_CONFIG_DIR`), else the default
/// one: its `.credentials.json` OAuth login where the CLI keeps one in a file,
/// or the OAuth account `.claude.json` names (macOS keeps the token in the
/// Keychain, so the file is all there is to read). The email comes from
/// `.claude.json`.
fn claude_login(folder: Option<&Path>) -> Login {
    let Some(home) = dirs::home_dir() else { return Login::default() };
    let (store, file) = match folder {
        Some(folder) => (folder.to_path_buf(), folder.join(".claude.json")),
        None => (home.join(".claude"), home.join(".claude.json")),
    };
    let credentials = crate::agent_login::signed_in_at(crate::agent_login::Agent::Claude, &store);
    let Ok(text) = std::fs::read_to_string(file) else {
        return Login { signed_in: credentials, ..Login::default() };
    };
    let v: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
    let account = v.get("oauthAccount");
    let text_at = |key: &str| {
        account
            .and_then(|a| a.get(key))
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
    };
    Login {
        signed_in: credentials || account.is_some_and(|a| !a.is_null()),
        plan: None,
        email: text_at("emailAddress"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_is_the_family_binding_then_the_global_one_then_the_cli_login() {
        let mut b = routes::Bindings::default();
        assert!(is_default(&b, "claude", "claude-login", true));
        assert!(!is_default(&b, "claude", "claude-2", false));
        b.global = Some("claude-2".into());
        assert!(is_default(&b, "claude", "claude-2", false));
        assert!(!is_default(&b, "claude", "claude-login", true));
        b.families.insert("claude".into(), "claude-3".into());
        assert!(is_default(&b, "claude", "claude-3", false));
        assert!(!is_default(&b, "claude", "claude-2", false));
    }

    #[test]
    fn a_codex_login_names_its_plan_and_email_from_the_id_token() {
        let dir = std::env::temp_dir().join(format!("acpmux-accounts-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let claims = json!({"email": "alex@example.com",
                            "https://api.openai.com/auth": {"chatgpt_plan_type": "pro"}});
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims.to_string());
        let auth = json!({"tokens": {"id_token": format!("h.{payload}.s"), "refresh_token": "x"}});
        std::fs::write(dir.join("auth.json"), auth.to_string()).unwrap();
        let login = codex_login(&dir);
        assert!(login.signed_in);
        assert_eq!(login.plan.as_deref(), Some("pro"));
        assert_eq!(login.email.as_deref(), Some("alex@example.com"));
        std::fs::write(dir.join("auth.json"), "{}").unwrap();
        assert!(!codex_login(&dir).signed_in, "an empty login file is not a login");
        std::fs::remove_file(dir.join("auth.json")).unwrap();
        assert!(!codex_login(&dir).signed_in);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
