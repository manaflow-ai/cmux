//! What the `/status` card says of a Claude chat beyond its model (Leo, 2026-11-03: "how come
//! the status doesn't say anything"): the sign-in its agent started with, the route it reaches
//! its provider on, and the settings files in force. Read from the spawn env acpmux remembered
//! for the chat (`claude_auth::remember`) and the files Claude Code reads, never a credential's
//! value: only its kind and where it came from. The session detail carries these as
//! `authSource`, `route` and `settingsSources` (`hub/views.rs`); the web only renders them.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::claude_auth::{self, Found};

/// How long one read of the files stands: the detail is built on every attach and info read,
/// and `~/.claude.json` can be megabytes.
const FRESH: Duration = Duration::from_secs(30);

/// What a read was made from, so a new spawn (another route, profile or folder) reads again.
#[derive(Clone, PartialEq)]
struct Inputs {
    env: BTreeMap<String, String>,
    route: Option<String>,
    cwd: PathBuf,
    argv: Vec<String>,
}

type Cached = HashMap<String, (Instant, Inputs, StatusFacts)>;
static CACHE: Mutex<Option<Cached>> = Mutex::new(None);

/// The card's rows for one chat.
#[derive(Debug, Clone, PartialEq)]
pub struct StatusFacts {
    pub auth_source: String,
    pub route: String,
    pub settings: Vec<String>,
    /// The account has plan usage limits Claude Code can report: a subscription login, or a
    /// router in front of subscription accounts. An API key, a cloud provider or another
    /// endpoint has none, so the card hides the row rather than wait for one.
    pub plan_limits: bool,
}

/// Whether a chat signed in with `auth` on `route` has plan usage limits ([`StatusFacts`]).
pub fn has_plan_limits(auth: &str, route: &str) -> bool {
    ["Claude subscription", "Claude OAuth token"].iter().any(|k| auth.starts_with(k))
        || ["SR2", "Subrouter"].iter().any(|k| route.starts_with(k))
}

/// A launcher that brings its own sign-in and endpoint (the harness argv): the env acpmux saw
/// is not the one Claude Code runs with.
fn launcher(argv: &[String]) -> Option<(&'static str, &'static str)> {
    let program = argv.first().map(|a| a.rsplit('/').next().unwrap_or(a));
    match program {
        Some("sr2") if argv.get(1).is_some_and(|a| a.starts_with("claude")) => {
            Some(("SR2 token (sr2 claude)", "SR2 (sr2 claude)"))
        }
        _ if crate::config::is_subrouter_proxy(argv) => {
            Some(("Subrouter account pool (sr claude proxy)", "Subrouter (sr claude proxy)"))
        }
        _ => None,
    }
}

/// The kind of credential a key carries, in the card's words.
fn kind_of(key: &str) -> &'static str {
    match key {
        "CLAUDE_CODE_USE_BEDROCK" => "Amazon Bedrock",
        "CLAUDE_CODE_USE_VERTEX" => "Google Vertex AI",
        "CLAUDE_CODE_USE_FOUNDRY" => "Microsoft Foundry",
        "ANTHROPIC_AUTH_TOKEN" => "Auth token",
        "ANTHROPIC_API_KEY" => "API key",
        "CLAUDE_CODE_OAUTH_TOKEN" => "Claude OAuth token",
        _ => "Credential",
    }
}

/// Claude Code's order among its sign-in sources: a cloud provider, then the auth token, the
/// API key, an API key helper, an OAuth token, a key `/login` saved, the subscription login.
const PRECEDENCE: [&str; 9] = [
    "CLAUDE_CODE_USE_",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_API_KEY",
    "apiKeyHelper",
    "aws",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "API key saved",
    "sign-in saved",
    "",
];

/// A source's place in [`PRECEDENCE`], by its leading words (a path inside it never counts).
fn rank(source: &str) -> usize {
    let head = source.split(" in ").next().unwrap_or(source);
    PRECEDENCE.iter().position(|needle| head.contains(needle)).unwrap_or(PRECEDENCE.len())
}

/// The sign-in Claude Code uses from `found`, and where it came from: `origin` names where an
/// env key was set (a route, the profile, the daemon's environment).
pub fn auth_label(found: &Found, origin: impl Fn(&str) -> String) -> String {
    let Some(source) = found.sources.iter().min_by_key(|s| rank(s)) else {
        // A sign-in kept only in the macOS keychain is never read (`claude_auth.rs`).
        return if cfg!(target_os = "macos") {
            "Claude subscription (keychain)".into()
        } else {
            "No sign-in found".into()
        };
    };
    if let Some(key) = found.env_keys.iter().find(|k| source.contains(k.as_str())) {
        return format!("{} ({key}, {})", kind_of(key), origin(key));
    }
    if let Some(at) = source.strip_prefix("the sign-in saved in ") {
        return format!("Claude subscription ({at})");
    }
    if let Some(at) = source.strip_prefix("the API key saved in ") {
        return format!("API key saved by /login ({at})");
    }
    if source.starts_with("apiKeyHelper") {
        return format!("API key helper ({source})");
    }
    match source.split_once(" in ") {
        Some((key, _)) => format!("{} ({source})", kind_of(key)),
        None => source.clone(),
    }
}

/// How the agent reaches its provider: a bound route by name, else its endpoint, else direct.
pub fn route_label(found: &Found, route_name: Option<&str>, base_url: Option<&str>) -> String {
    let host = found.endpoint.as_deref();
    if let Some(name) = route_name {
        return match host {
            Some(host) => format!("{name} ({host})"),
            None => name.to_owned(),
        };
    }
    if let Some(provider) = found.env_keys.iter().find(|k| k.starts_with("CLAUDE_CODE_USE_")) {
        return kind_of(provider).to_owned();
    }
    let Some(host) = host else { return "Direct (Anthropic)".into() };
    let name = host.split(':').next().unwrap_or(host);
    if base_url.is_some_and(crate::sr2_cost_labels::is_sr2_gateway) {
        format!("SR2 gateway ({host})")
    } else if name.contains("subrouter") {
        format!("Subrouter ({host})")
    } else if name == "anthropic.com" || name.ends_with(".anthropic.com") {
        format!("Direct ({host})")
    } else {
        format!("Custom endpoint ({host})")
    }
}

/// The settings files Claude Code reads for a chat in `cwd` that exist, as paths under `~`,
/// and the autocompact window it starts with when one is set.
pub fn settings_in_force(home: &Path, cwd: &Path, autocompact: Option<&str>) -> Vec<String> {
    let mut files = claude_auth::settings_files(home);
    files.push(cwd.join(".claude/settings.json"));
    files.push(cwd.join(".claude/settings.local.json"));
    let mut out: Vec<String> =
        files.iter().filter(|f| f.is_file()).map(|f| claude_auth::tilde(f)).collect();
    if let Some(window) = autocompact.and_then(|w| w.trim().parse::<u64>().ok()) {
        out.push(format!("autocompact at {}K", window / 1000));
    }
    out
}

/// The card's rows for chat `session_id` in `cwd`, whose agent last started with `argv`;
/// `in_profile` says whether its profile env set a key. None when acpmux remembers no Claude
/// spawn for it (another harness, or no start yet).
pub fn facts(
    session_id: &str,
    cwd: &Path,
    argv: &[String],
    in_profile: impl Fn(&str) -> bool,
) -> Option<StatusFacts> {
    let spawned = claude_auth::spawned(session_id)?;
    let inputs = Inputs {
        env: spawned.env.clone(),
        route: spawned.route.clone(),
        cwd: cwd.to_owned(),
        argv: argv.to_vec(),
    };
    {
        let cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, was, facts)) = cache.as_ref().and_then(|c| c.get(session_id))
            && *was == inputs
            && at.elapsed() < FRESH
        {
            return Some(facts.clone());
        }
    }
    // File reads block: off a multi-thread runtime's workers, as `claude_auth::explain`.
    let work = || read(&spawned, cwd, argv, in_profile);
    let multi_thread = tokio::runtime::Handle::try_current()
        .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread);
    let facts = if multi_thread { tokio::task::block_in_place(work) } else { work() };
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    let cache = cache.get_or_insert_with(HashMap::new);
    cache.retain(|_, (at, _, _)| at.elapsed() < FRESH);
    cache.insert(session_id.to_owned(), (Instant::now(), inputs, facts.clone()));
    Some(facts)
}

fn read(
    spawned: &claude_auth::Spawned,
    cwd: &Path,
    argv: &[String],
    in_profile: impl Fn(&str) -> bool,
) -> StatusFacts {
    let found = claude_auth::find_in(&spawned.env, cwd);
    let settings = settings_in_force(
        &found.home,
        cwd,
        spawned.env.get(crate::harness_limits::CLAUDE_AUTOCOMPACT_WINDOW.0).map(String::as_str),
    );
    if let Some((auth, route)) = launcher(argv) {
        return StatusFacts {
            auth_source: auth.into(),
            route: route.into(),
            settings,
            plan_limits: true,
        };
    }
    let origin = |key: &str| match &spawned.route {
        Some(name) if spawned.routed => format!("from route {name}"),
        _ if spawned.routed => "from its route".to_owned(),
        _ if in_profile(key) => "from its profile".to_owned(),
        _ => "from the environment".to_owned(),
    };
    let auth_source = auth_label(&found, origin);
    let route = route_label(
        &found,
        spawned.route.as_deref(),
        spawned.env.get("ANTHROPIC_BASE_URL").map(String::as_str),
    );
    let plan_limits = has_plan_limits(&auth_source, &route);
    StatusFacts { auth_source, route, settings, plan_limits }
}

#[cfg(test)]
#[path = "session_status_tests.rs"]
mod tests;
