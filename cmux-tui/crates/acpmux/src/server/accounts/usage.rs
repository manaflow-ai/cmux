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
    let (dir, _) = routes::places(&*hub.config.read().await);
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
            let limits = read(&home).await?;
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

/// One `account/rateLimits/read` in `home`: its `usageLimits`, null when Codex reports no plan
/// limit. A Codex that cannot be found, does not start or does not answer is an error.
async fn read(home: &Path) -> Result<Value, RpcError> {
    let codex = crate::managed_codex::codex_binary()
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
mod tests {
    use super::*;

    const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");

    fn home(name: &str) -> PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("acpmux-account-usage-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn only_a_signed_in_file_login_on_the_openai_sign_in_is_read() {
        let dir = home("readable");
        assert_eq!(readable(&dir), Target::Skip("signedOut"));
        std::fs::write(dir.join("auth.json"), r#"{"tokens": {"access_token": "x"}}"#).unwrap();
        assert_eq!(readable(&dir), Target::Read(dir.clone()));
        // A login Codex may keep in the keychain is never asked for (cx-hh0vu).
        for store in ["keyring", "auto"] {
            let config = format!("cli_auth_credentials_store = \"{store}\"\n");
            std::fs::write(dir.join("config.toml"), config).unwrap();
            assert_eq!(readable(&dir), Target::Skip("keychain"), "{store}");
        }
        std::fs::write(dir.join("config.toml"), "cli_auth_credentials_store = \"file\"\n").unwrap();
        assert_eq!(readable(&dir), Target::Read(dir.clone()));
        // A provider without the OpenAI sign-in has no plan limits.
        let sr =
            "model_provider = \"sr\"\n[model_providers.sr]\nexperimental_bearer_token = \"t\"\n";
        std::fs::write(dir.join("config.toml"), sr).unwrap();
        assert_eq!(readable(&dir), Target::Skip("provider"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_read_runs_codex_in_the_accounts_home_with_a_file_login_and_maps_its_windows() {
        let dir = home("read");
        let args = dir.join("args.jsonl");
        let seen = dir.join("codex-home.txt");
        // FAKE_CODEX_ARGS: where the fake records its arguments; FAKE_CODEX_HOME_SEEN: its CODEX_HOME.
        let env = BTreeMap::from([
            ("FAKE_CODEX_ARGS".to_owned(), args.display().to_string()),
            ("FAKE_CODEX_HOME_SEEN".to_owned(), seen.display().to_string()),
        ]);
        let limits = read_with(vec!["python3".into(), FAKE.into()], &dir, env).await.unwrap();
        assert_eq!(
            limits,
            json!({
                "windows": [
                    {"id": "session", "usedPercent": 22.0, "windowMins": 300, "resetsAt": 1_790_000_000},
                    {"id": "weekly", "usedPercent": 41.0, "windowMins": 10080, "resetsAt": 1_790_500_000},
                ],
                "plan": "pro",
                "credits": {"balance": "56766"},
            })
        );
        let recorded = std::fs::read_to_string(&args).unwrap();
        let first: Vec<String> = serde_json::from_str(recorded.lines().next().unwrap()).unwrap();
        assert_eq!(first, ["-c", "cli_auth_credentials_store=\"file\"", "app-server"]);
        let home_seen = std::fs::read_to_string(&seen).unwrap();
        assert_eq!(home_seen.trim(), dir.display().to_string());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
