//! `_acpmux/account/usage {id}`: an account's plan usage limits at rest, the 5-hour and weekly
//! windows Settings > Agents > Harnesses shows under each account (Leo, 2026-11-05: "i meant can
//! you do all of htem", the accounts list's "show 5-hour and weekly usage per account at rest").
//! A chat gets them from Codex's `account/rateLimits/updated` during a turn; here one short-lived
//! `codex app-server` in the account's `CODEX_HOME` answers `account/rateLimits/read`, mapped as
//! the chat's (`codex_app_server::read_usage_limits`), and is stopped.
//!
//! Only on a caller's ask (Settings asks when its page refreshes), never on a timer of its own.
//! It never asks the login keychain (cx-hh0vu): a login Codex may keep there, a model provider
//! without the OpenAI sign-in, a signed-out login and agent launches turned off answer `skipped`
//! and start nothing; Codex runs with `cli_auth_credentials_store="file"`. Claude Code reports
//! its limits only during a turn, so a Claude account answers `skipped` too. No credential is
//! read or returned here: the app-server reads its own login file.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::hub::Hub;
use crate::routes::{self, RouteKind};
use crate::rpc::RpcError;
use crate::server::Origin;

/// Start to answer: the app-server starts in about a second and asks ChatGPT once.
// timeout: a Codex app-server that never answers fails this usage read, not the page.
const READ_TIMEOUT: Duration = Duration::from_secs(15);
/// A read this recent answers again: a page refresh after each gesture starts no new Codex.
const FRESH: Duration = Duration::from_secs(60);
/// At most this many Codex processes read at once, however many accounts or callers ask.
static READS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(3);
/// The last answer per login folder, with when it was read.
static LAST: LazyLock<Mutex<HashMap<PathBuf, (Instant, Value)>>> = LazyLock::new(Default::default);

/// What to do for one account: read the login in `home`, or answer why not.
#[derive(Debug, PartialEq)]
enum Target {
    Read(PathBuf),
    Skip(&'static str),
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    origin: Origin,
    params: &Value,
) -> Result<Value, RpcError> {
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "account usage is read only from the local app or the unix socket",
        ));
    }
    let id = params
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("id is required"))?
        .to_owned();
    let (dir, configured) = {
        let config = hub.config.read().await;
        let home = dirs::home_dir().unwrap_or_default();
        (routes::places(&config).0, codex_path(&config, &home))
    };
    let lookup = id.clone();
    let target = tokio::task::spawn_blocking(move || target(dir.as_deref(), &lookup))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))??;
    let home = match target {
        Target::Skip(why) => return Ok(json!({"id": id, "usageLimits": null, "skipped": why})),
        Target::Read(home) => home,
    };
    let fresh = LAST.lock().ok().and_then(|last| {
        last.get(&home).filter(|(at, _)| at.elapsed() < FRESH).map(|(_, v)| v.clone())
    });
    let limits = match fresh {
        Some(limits) => limits,
        None => {
            let limits = read(configured, &home).await?;
            if let Ok(mut last) = LAST.lock() {
                last.insert(home, (Instant::now(), limits.clone()));
            }
            limits
        }
    };
    Ok(json!({"id": id, "usageLimits": limits}))
}

/// The login folder of account `id`, or why its usage is not read.
fn target(dir: Option<&Path>, id: &str) -> Result<Target, RpcError> {
    if id == super::CLAUDE_LOGIN_ID {
        return Ok(Target::Skip("claude"));
    }
    let route = routes::find(dir, id).map_err(|e| crate::hub::route_error(&e))?;
    let builtin = id == routes::CODEX_LOGIN_ROUTE_ID;
    if route.file.kind != RouteKind::DirectSubscription
        || (!builtin && route.file.account_home.is_none())
    {
        return Err(RpcError::invalid_params(format!("{id} is not an account")));
    }
    match route.file.families.as_slice() {
        [f] if f == "codex" => {}
        [f] if f == "claude" => return Ok(Target::Skip("claude")),
        _ if builtin => {}
        _ => return Err(RpcError::invalid_params(format!("{id} is not an account"))),
    }
    let home = route.file.account_home.clone().map(PathBuf::from);
    let Some(home) = home.or_else(crate::route_shadow::codex_base) else {
        return Ok(Target::Skip("signedOut"));
    };
    Ok(readable(&home))
}

/// Whether the Codex login in `home` may be read: never one that would start Codex while
/// launches are off, a signed-out one, or one that may ask the keychain.
fn readable(home: &Path) -> Target {
    if crate::launch_policy::agent_launch_disabled() {
        return Target::Skip("launchesOff");
    }
    if !crate::agent_login::signed_in_at(crate::agent_login::Agent::Codex, home) {
        return Target::Skip("signedOut");
    }
    match crate::harness_health::codex_usage_unreadable(home) {
        Some(why) => Target::Skip(why),
        None => Target::Read(home.to_path_buf()),
    }
}

/// The Codex a Codex harness profile runs (`CODEX_PATH` of the profile, else of its defaults
/// (`defaults.codex.env`), as its launch and its model list pick it; the `codex` profile first),
/// or None for the one on PATH. `${home}`, `${model}` and `~/` expand as a chat launch expands
/// them (`hub::expand_env_value`) with `home` and the family's default model; a read at rest has
/// no directory, so a `${cwd}` one, or one with a variable left over, is not a path.
fn codex_path(config: &crate::config::Config, home: &Path) -> Option<String> {
    let own = |name: &str, profile: &crate::config::HarnessProfile| {
        let defaults = config.defaults_for(name);
        let path = profile.env.get("CODEX_PATH").or_else(|| defaults.env.get("CODEX_PATH"))?;
        if path.contains("${cwd}") {
            return None;
        }
        let model = defaults.model.unwrap_or_default();
        let path = crate::hub::expand_env_value(path, home, home, &model);
        (!path.is_empty() && !path.contains("${")).then_some(path)
    };
    let mut codex = config.harnesses.iter().filter(|(name, profile)| {
        profile.kind == crate::config::HarnessKind::Acp
            && crate::config::derive_family(name, profile) == "codex"
    });
    config
        .harnesses
        .get("codex")
        .and_then(|p| own("codex", p))
        .or_else(|| codex.find_map(|(name, p)| own(name, p)))
}

/// One `account/rateLimits/read` in `home` with `configured` Codex (else the one on PATH): its
/// `usageLimits`, null when Codex reports no plan limit. A Codex that cannot be found, does not
/// start or does not answer is an error.
async fn read(configured: Option<String>, home: &Path) -> Result<Value, RpcError> {
    let codex = configured
        .or_else(crate::managed_codex::codex_binary)
        .ok_or_else(|| RpcError::invalid_params("Codex is not installed"))?;
    read_with(vec![codex], home, BTreeMap::new()).await
}

/// [`read`] with `program` as the Codex command line before its options, and `env` added.
async fn read_with(
    program: Vec<String>,
    home: &Path,
    mut env: BTreeMap<String, String>,
) -> Result<Value, RpcError> {
    let _turn = READS.acquire().await.map_err(|e| RpcError::internal(e.to_string()))?;
    let mut argv = program;
    argv.extend(["-c".to_owned(), "cli_auth_credentials_store=\"file\"".to_owned()]);
    env.insert("CODEX_HOME".to_owned(), home.display().to_string());
    let result = crate::live_models::codex_rate_limits(&argv, &env, home, READ_TIMEOUT)
        .await
        .map_err(|e| RpcError::internal(format!("Codex usage limits: {e}")))?;
    Ok(crate::codex_app_server::read_usage_limits(&result).unwrap_or(Value::Null))
}

#[cfg(test)]
mod tests;
