//! `cmux setup harness [ID ...] [--dry-run]`: whether each agent harness
//! (Claude Code, Codex, OpenCode, Gemini, ...) is installed, signed in and
//! current, and the one thing the person does when it is not.
//!
//! The check is acpmux's own health check (`acpmux::harness_health`, the
//! rows `_acpmux/harness/health` serves), run here as a library so it is
//! fresh and needs no daemon: where the program is, its `--version`, and
//! its sign-in from evidence (the profile's `auth.check`, the agent's own
//! login files). A sign-in that evidence leaves unknown on an ACP harness
//! is asked of the harness itself, as `cmux harness login ID --status`
//! does (`initialize` and `session/new` in a private temp folder), never
//! with a prompt turn: `cmux harness doctor` stays the deep check. Setup
//! reads no keychain itself, as the check does not, and does not ask one
//! whose sign-in may be there (`keychain_sign_in`). Whether it is outdated
//! comes from the newest version the daemon last read (its saved copy), so
//! setup asks no registry itself.
//!
//! Installing a CLI and signing in are the person's, and an update has no
//! undo, so this task writes nothing: each harness is `ok` or `needs_user`,
//! and an outdated one names the command that updates it.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

use acpmux::cli::harness_login::{self, AuthState};
use acpmux::config::profiles::{self, ProfileSource};
use acpmux::config::{Config, HarnessProfile, ProfileMeta, UNIICHAT_PROFILE};
use acpmux::harness_health::{Auth, HarnessHealth, HealthService, Settings, Subject, probe};
use serde_json::{Value, json};

use super::{Outcome, Refusal};

const TASK: &str = "harness";

/// The longest a harness may take to answer `initialize`, then
/// `session/new`, when its sign-in is asked of it.
const ASK_TIMEOUT: Duration = Duration::from_secs(20);

struct Request {
    ids: BTreeSet<String>,
    dry_run: bool,
}

pub(super) fn run(args: &[String]) -> Result<Outcome, Refusal> {
    let request = parse(args)?;
    let (harnesses, user_action) = check(&request.ids)?;
    let report = json!({
        "schema_version": 1,
        "task": TASK,
        "state": state(&user_action),
        "dry_run": request.dry_run,
        "harnesses": harnesses,
        "undo": Value::Null,
        "user_action": user_action,
    });
    Ok(Outcome { report, failed: false })
}

/// The harness check `cmux setup status` reports: every configured or
/// found harness. A config that does not load fails this check only.
pub(super) fn status() -> Value {
    match check(&BTreeSet::new()) {
        Ok((harnesses, user_action)) => json!({
            "task": TASK,
            "state": state(&user_action),
            "harnesses": harnesses,
            "user_action": user_action,
        }),
        Err(Refusal::Usage(message) | Refusal::Failed(message)) => {
            json!({"task": TASK, "state": "failed", "error": message})
        }
    }
}

fn parse(args: &[String]) -> Result<Request, Refusal> {
    let mut request = Request { ids: BTreeSet::new(), dry_run: false };
    for arg in args {
        match arg.as_str() {
            "--dry-run" => request.dry_run = true,
            flag if flag.starts_with('-') => {
                return Err(Refusal::Usage(format!(
                    "cmux: setup harness: unknown option {flag:?}"
                )));
            }
            id => {
                request.ids.insert(id.to_owned());
            }
        }
    }
    Ok(request)
}

fn state(user_action: &Value) -> &'static str {
    if user_action.is_null() { "ok" } else { "needs_user" }
}

/// Each harness's report, and the first thing the person must do.
fn check(ids: &BTreeSet<String>) -> Result<(Vec<Value>, Value), Refusal> {
    crate::acp::configure_home();
    let mut cfg = Config::load()
        .map_err(|error| Refusal::Failed(format!("cmux: setup harness: {error:#}")))?;
    let configured: BTreeSet<String> = cfg.harnesses.keys().cloned().collect();
    let ids = if ids.is_empty() { found(&cfg) } else { ids.clone() };
    for id in ids.iter().filter(|id| !configured.contains(*id)) {
        let (profile, meta) = shipped(id).ok_or_else(|| {
            Refusal::Usage(format!(
                "cmux: setup harness: no harness {id:?}; `cmux harness list` names them"
            ))
        })?;
        cfg.harnesses.insert(id.clone(), profile);
        cfg.profile_meta.insert(id.clone(), meta);
    }
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|error| Refusal::Failed(format!("cmux: setup harness: {error}")))?;
    let rows = runtime.block_on(health(&cfg, &ids));
    let saved = saved();
    let harnesses: Vec<Value> =
        rows.into_iter().map(|row| report(&cfg, &configured, &saved, row)).collect();
    let user_action = match harnesses.iter().map(|h| &h["user_action"]).find(|a| !a.is_null()) {
        Some(action) => action.clone(),
        None if ids.is_empty() => none_installed(),
        None => Value::Null,
    };
    Ok((harnesses, user_action))
}

/// Every configured or discovered harness. UniiChat is offered on every
/// machine (the bundled adapter, nothing to install), so it counts only
/// when it is named or has a profile.
fn found(cfg: &Config) -> BTreeSet<String> {
    cfg.harnesses
        .keys()
        .filter(|id| !(id.as_str() == UNIICHAT_PROFILE && cfg.discovered.contains(*id)))
        .cloned()
        .collect()
}

/// The profile acpmux ships for `id` (`cmux harness add --example ID`), so a
/// harness not set up yet is checked as it would run, and its docs say how
/// to install it.
fn shipped(id: &str) -> Option<(HarnessProfile, ProfileMeta)> {
    // By its id only: an alias (`claude-code`) is not a harness id.
    let (_, text) = acpmux::cli::harness::EXAMPLES.iter().find(|(name, _)| *name == id)?;
    let path = PathBuf::from(format!("{id}.toml"));
    let (_, profile, meta, _) =
        profiles::parse_profile_toml(text, &path, Some(id), ProfileSource::UserFile).ok()?;
    Some((profile, meta))
}

/// acpmux's health check of `ids`, with an unknown sign-in asked of each
/// installed harness.
async fn health(cfg: &Config, ids: &BTreeSet<String>) -> Vec<HarnessHealth> {
    let subjects = ids
        .iter()
        .filter_map(|id| {
            let auth = cfg.profile_meta.get(id).and_then(|meta| meta.auth.as_ref());
            Subject::of(id, cfg.harnesses.get(id)?, auth)
        })
        .collect();
    let service = HealthService::new();
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    service.attach(Settings { home, ..Settings::default() });
    let rows = service.check(subjects, false).await;
    futures_util::future::join_all(rows.into_iter().map(|row| ask(cfg, row))).await
}

/// The harness's own answer to an unknown sign-in. None while agent
/// launches are off, and none for a harness without ACP sign-in (a
/// terminal harness): those stay unknown, with the reason. An unknown the
/// check explained (a provider credential that is not set) stays as it
/// said, and a harness whose sign-in may be in the login keychain is not
/// asked: setup reads no keychain itself, as the check does not (cx-hh0vu).
async fn ask(cfg: &Config, mut row: HarnessHealth) -> HarnessHealth {
    if row.auth != Auth::Unknown || row.auth_detail.is_some() || row.path.is_none() {
        return row;
    }
    if acpmux::launch_policy::agent_launch_disabled() {
        row.auth_detail = Some("agent launches are off, so setup did not ask the harness".into());
        return row;
    }
    let Some(profile) = cfg.harnesses.get(&row.id) else { return row };
    if let Some(why) = acpmux::harness_health::keychain_sign_in(&row.id, profile) {
        row.auth_detail = Some(format!(
            "the sign-in may be in the login keychain ({why}), which setup does not read"
        ));
        return row;
    }
    match harness_login::auth_state(cfg, &row.id, ASK_TIMEOUT).await {
        Ok(AuthState::SignedIn { .. }) => {
            row.auth = Auth::SignedIn;
            row.auth_detail = Some("the harness answered `session/new`".into());
        }
        Ok(AuthState::Required { message, .. }) => {
            row.auth = Auth::SignedOut;
            row.auth_detail = Some(message);
        }
        Ok(AuthState::NotAcp { hint }) => row.auth_detail = Some(hint),
        Err(error) => row.auth_detail = Some(format!("{error:#}")),
    }
    row
}

/// The daemon's last check (`<acpmux home>/harness-health.json`), for the
/// newest versions it read; empty when it never ran.
fn saved() -> Vec<HarnessHealth> {
    std::fs::read(acpmux::config::home().join("harness-health.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn report(
    cfg: &Config,
    configured: &BTreeSet<String>,
    saved: &[HarnessHealth],
    row: HarnessHealth,
) -> Value {
    let meta = cfg.profile_meta.get(&row.id);
    let name = meta.and_then(|meta| meta.display_name.clone()).unwrap_or_else(|| row.id.clone());
    let configured = configured.contains(&row.id);
    // The newest version the daemon read for this install, however old: a
    // version below it is outdated either way.
    let latest = saved
        .iter()
        .find(|s| s.id == row.id && s.channel == row.channel && s.package == row.package)
        .and_then(|s| s.latest.clone());
    let outdated =
        latest.as_deref().zip(row.version.as_deref()).map(|(l, v)| probe::is_newer(l, v));
    let user_action = if row.path.is_none() {
        let docs = meta
            .and_then(docs_url)
            .or_else(|| shipped(&row.id).and_then(|(_, meta)| docs_url(&meta)));
        install(&name, &row.program, docs)
    } else if matches!(row.auth, Auth::SignedOut | Auth::Expired) {
        // `cmux harness login` knows only a configured harness; the
        // profile's own login command signs in one that is not yet.
        let command = match (configured, &row.login) {
            (false, Some(login)) => login.clone(),
            _ => format!("cmux harness login {}", super::super::fix_command::quote_arg(&row.id)),
        };
        json!({
            "kind": "oauth",
            "text": format!(
                "Sign in to {name}: run `{command}` in a terminal and finish the sign-in it opens"
            ),
            "command": command,
            "url": Value::Null,
        })
    } else {
        Value::Null
    };
    json!({
        "id": row.id,
        "name": name,
        "state": state(&user_action),
        "configured": configured,
        "installed": row.path.is_some(),
        "program": row.program,
        "path": row.path,
        "version": row.version,
        "signed_in": match row.auth {
            Auth::SignedIn => Some(true),
            Auth::SignedOut | Auth::Expired => Some(false),
            Auth::Unknown => None,
        },
        "auth_detail": row.auth_detail,
        "outdated": outdated,
        "latest": latest,
        "update": row.update.filter(|_| outdated == Some(true)).map(|plan| plan.command),
        "problem": row.problem,
        "user_action": user_action,
    })
}

/// The install docs a profile names.
fn docs_url(meta: &ProfileMeta) -> Option<String> {
    meta.auth.as_ref()?.docs.clone()
}

/// Installing `program`, the person's: the profile's docs say how.
fn install(name: &str, program: &str, docs: Option<String>) -> Value {
    let program = Path::new(program)
        .file_name()
        .map_or_else(|| program.to_owned(), |name| name.to_string_lossy().into_owned());
    let see = docs.as_deref().map(|url| format!(" (see {url})")).unwrap_or_default();
    json!({
        "kind": "install",
        "text": format!("Install {name}: `{program}` is not on PATH{see}"),
        "command": Value::Null,
        "url": docs,
    })
}

/// No harness configured or found: the person installs one, Claude Code by
/// the shipped profile's docs unless they pick another.
fn none_installed() -> Value {
    let docs = shipped("claude").and_then(|(_, meta)| docs_url(&meta));
    let see = docs.as_deref().map(|url| format!(" (see {url})")).unwrap_or_default();
    json!({
        "kind": "install",
        "text": format!(
            "No agent CLI is installed: install Claude Code{see}, Codex, OpenCode or Gemini"
        ),
        "command": Value::Null,
        "url": docs,
    })
}
