//! Where a harness's readiness answer comes from (teardown row 7, ledger a30064a63f): the
//! machine whose daemon answered, the account home the harness reads, who owns the credential
//! it signs in with, the configuration that defined it, and whether it is eligible to run.
//! Computed when `_acpmux/harness/health` answers and when a chat's detail is read
//! (`hub/health_view.rs`, `hub/views.rs`); the web only renders it.
//!
//! Every value is a fixed word or a sanitized name (a folder's or file's last part, a machine
//! name). Never a credential's value, a credential file's contents, a full path or raw error
//! text: a probe error is only matched, never copied. A value nothing reports is `unknown`.

use super::{Auth, HarnessHealth, channel::Channel};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::LazyLock;

/// The account home a harness reads (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`).
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AccountHome {
    /// The harness's own default home: no profile or login shell names another.
    Default,
    /// Its profile names a home of its own.
    Profile,
    /// The login shell (or the daemon's env) names one: the terminal's working account, which
    /// can differ from the profile's.
    Environment,
    /// Its profile sets it by a reference (`${...}`) resolved only at start.
    Unresolved,
    /// acpmux knows no account home for this harness.
    Unknown,
}

/// Who supplies the credential the harness signs in with.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CredentialOwner {
    /// A launcher that brings its own sign-in (`sr2 claude`, `sr claude proxy`).
    Launcher,
    /// A route bound to the chat supplied the environment.
    Route,
    /// The harness profile's env names a credential.
    Profile,
    /// The login shell or the daemon's env holds a provider credential.
    Environment,
    /// The harness's own sign-in (its login file or status command answered).
    AgentLogin,
    Unknown,
}

/// The configuration that defined the harness.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ConfigSource {
    /// A managed (company) profile folder.
    Managed,
    /// A profile file of the person's.
    ProfileFile,
    /// cmux.json.
    CmuxJson,
    /// acpmux's own config.json.
    ConfigFile,
    /// Found on PATH, with no profile.
    Discovered,
    /// A capture fixture's rows.
    Fixture,
    Unknown,
}

/// Whether the harness can run its work, and the one reason it may not.
#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Eligibility {
    /// Signed in, with nothing saying its account lacks access.
    Eligible,
    /// Its program is not on this machine.
    NotInstalled,
    /// Signed out.
    SignInNeeded,
    /// Its credential expired.
    Expired,
    /// The credential works but the account lacks the workspace, plan or feature (a different
    /// repair from signing in again).
    NotEntitled,
    /// Nothing proves either way; a chat still starts.
    Unknown,
}

/// Where one harness's readiness answer comes from.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Provenance {
    /// The machine whose daemon answered, by its name.
    pub machine: String,
    pub account: AccountHome,
    /// The account home's folder name, when one is named (never the full path).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_name: Option<String>,
    pub credential: CredentialOwner,
    pub config: ConfigSource,
    /// The profile file's name, when a file defined it (never the full path).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config_name: Option<String>,
    pub eligibility: Eligibility,
}

/// What [`of`] reads. Values in `profile_env` and `login_env` are read only to tell which keys
/// are set and the account home's folder name; none is copied out.
pub struct Inputs<'a> {
    pub family: &'a str,
    /// The command line the harness runs (a launcher brings its own sign-in).
    pub argv: &'a [String],
    pub profile_env: &'a BTreeMap<String, String>,
    /// The env the harness gets without its profile (`login_env::effective_for` with none).
    pub login_env: &'a BTreeMap<String, String>,
    pub config: ConfigSource,
    /// The profile file's path; only its file name is kept.
    pub config_path: Option<&'a str>,
    /// A route bound to the chat supplied its environment.
    pub routed: bool,
    pub row: Option<&'a HarnessHealth>,
    /// The hub's probe error for it: matched, never copied.
    pub probe_error: Option<&'a str>,
    pub machine: &'a str,
}

/// The provider credential keys a harness family reads from its environment.
fn provider_keys(family: &str) -> &'static [&'static str] {
    match family {
        f if f.starts_with("claude") => &[
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY",
        ],
        "codex" => &["OPENAI_API_KEY", "CODEX_API_KEY"],
        "gemini" => &["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        _ => &[],
    }
}

/// The account-home variable of a family (`route_account::home_var`, `claude-*` as `claude`).
fn home_var(family: &str) -> Option<&'static str> {
    let family = if family.starts_with("claude") { "claude" } else { family };
    crate::route_account::home_var(family)
}

/// A name safe to show: the last part of `path`, only letters, digits, `.`, `_` and `-`, at
/// most 40 characters. None when nothing is left.
pub fn sanitized_name(path: &str) -> Option<String> {
    let last = Path::new(path.trim_end_matches('/')).file_name()?.to_string_lossy().into_owned();
    let name: String = last
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(40)
        .collect();
    (!name.is_empty() && name != "." && name != "..").then_some(name)
}

static NOT_ENTITLED: LazyLock<Option<regex::Regex>> = LazyLock::new(|| {
    regex::Regex::new(concat!(
        r"(?i)\b(not entitled|not eligible|no access to (this |the )?(workspace|feature|model|organization)",
        r"|(workspace|organization) (is |has been )?(disabled|deactivated|suspended)",
        r"|not a member of (this |the |any )?(workspace|organization|team)",
        r"|(plan|subscription) (does not|doesn't) (include|support|allow)",
        r"|upgrade (your|to a) (plan|subscription)",
        r"|requires a (chatgpt|paid|pro|plus|team|business|enterprise|max) (plan|account|subscription))",
    ))
    .ok()
});

/// Whether `text` says the account lacks a workspace, plan or feature, as opposed to a sign-in
/// that is missing or expired.
pub fn says_not_entitled(text: &str) -> bool {
    NOT_ENTITLED.as_ref().is_some_and(|re| re.is_match(text))
}

fn eligibility(row: Option<&HarnessHealth>, probe_error: Option<&str>) -> Eligibility {
    let Some(row) = row else { return Eligibility::Unknown };
    if row.path.is_none() && row.channel != Channel::Launcher {
        return Eligibility::NotInstalled;
    }
    // A credential that works but an account without access: neither a sign-in nor expiry.
    let detail = row.auth_detail.as_deref();
    if [probe_error, detail].into_iter().flatten().any(says_not_entitled)
        && !matches!(row.auth, Auth::SignedOut | Auth::Expired)
    {
        return Eligibility::NotEntitled;
    }
    match row.auth {
        Auth::SignedIn => Eligibility::Eligible,
        Auth::SignedOut => Eligibility::SignInNeeded,
        Auth::Expired => Eligibility::Expired,
        Auth::Unknown => Eligibility::Unknown,
    }
}

/// Where the harness's readiness comes from.
pub fn of(i: &Inputs<'_>) -> Provenance {
    let set =
        |env: &BTreeMap<String, String>, key: &str| env.get(key).is_some_and(|v| !v.is_empty());
    let (account, account_name) = match home_var(i.family) {
        None => (AccountHome::Unknown, None),
        Some(var) => match i.profile_env.get(var).filter(|v| !v.is_empty()) {
            Some(v) if v.contains("${") => (AccountHome::Unresolved, None),
            Some(v) => (AccountHome::Profile, sanitized_name(v)),
            None => match i.login_env.get(var).filter(|v| !v.is_empty()) {
                Some(v) => (AccountHome::Environment, sanitized_name(v)),
                None => (AccountHome::Default, None),
            },
        },
    };
    let keys = provider_keys(i.family);
    let profile_credential = i.profile_env.iter().any(|(k, v)| {
        !v.is_empty() && (keys.contains(&k.as_str()) || crate::login_env::is_secret(k, ""))
    });
    let credential = if crate::session_status::launcher(i.argv).is_some() {
        CredentialOwner::Launcher
    } else if i.routed {
        CredentialOwner::Route
    } else if profile_credential {
        CredentialOwner::Profile
    } else if keys.iter().any(|k| set(i.login_env, k)) {
        CredentialOwner::Environment
    } else if i.row.is_some_and(|r| r.auth != Auth::Unknown) {
        CredentialOwner::AgentLogin
    } else {
        CredentialOwner::Unknown
    };
    let config_name = match i.config {
        ConfigSource::Managed | ConfigSource::ProfileFile | ConfigSource::CmuxJson => {
            i.config_path.and_then(sanitized_name)
        }
        _ => None,
    };
    Provenance {
        machine: sanitized_name(i.machine).unwrap_or_else(|| "unknown".into()),
        account,
        account_name,
        credential,
        config: i.config,
        config_name,
        eligibility: eligibility(i.row, i.probe_error),
    }
}

/// The config source of harness `id` in `cfg`.
pub fn config_source(cfg: &crate::config::Config, id: &str) -> (ConfigSource, Option<String>) {
    use crate::config::profiles::ProfileSource;
    if let Some(meta) = cfg.profile_meta.get(id) {
        let source = match meta.source {
            ProfileSource::Managed => ConfigSource::Managed,
            ProfileSource::UserFile => ConfigSource::ProfileFile,
            ProfileSource::CmuxJson => ConfigSource::CmuxJson,
        };
        return (source, Some(meta.source_path.clone()));
    }
    if cfg.discovered.contains(id) {
        return (ConfigSource::Discovered, None);
    }
    if cfg.harnesses.contains_key(id) {
        return (ConfigSource::ConfigFile, None);
    }
    (ConfigSource::Unknown, None)
}

/// The env a harness of `family` gets without its profile, once per family per answer.
pub fn login_envs<'a>(
    families: impl IntoIterator<Item = &'a str>,
) -> BTreeMap<String, BTreeMap<String, String>> {
    let empty = BTreeMap::new();
    families
        .into_iter()
        .map(|f| (f.to_owned(), crate::login_env::effective_for(Some(f), &empty)))
        .collect()
}

#[cfg(test)]
#[path = "provenance_tests.rs"]
mod tests;
