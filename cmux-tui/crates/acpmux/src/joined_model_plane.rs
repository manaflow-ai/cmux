//! Claude and Codex in team mode on a machine joined to the cmux hub that is not a cmux Cloud
//! image. Leo, 2026-11-21: "it's not like people buying our cloud product are gonna suddenly join
//! our tailnet. we have our own wireguard."
//!
//! A Cloud machine reaches its team's inference gateway through its own edge
//! (`codex_cloud_auth::Inputs::team_origin`). A joined machine (`acpmux machine join`) has no edge,
//! only its machine credential (`cmm_...`, `machine-credential.json`) and the hub origin it joined.
//! The hub's Worker serves the same gateway route at `<hub origin>/v1/messages`, `/v1/responses`
//! and `/v1/models` for a request carrying `x-cmux-inference-authorization: Bearer cmm_...`.
//!
//! The agent never holds the credential. Its launch gets the header with the vault placeholder
//! `cmux-secret://CMUX_MACHINE_CREDENTIAL` ([`header_value`]) and `HTTPS_PROXY` at this daemon's
//! egress proxy (`vault::egress::machine_credential_env`). The proxy fills that one name, and only
//! on a connection to the hub origin's host ([`secret`]); every other host gets the placeholder.
//!
//! Off by default. A launch opts in with `CMUX_CLAUDE_AUTH=team` / `CMUX_CODEX_AUTH=team`, or
//! `cr use`'s recorded choice `team` (`~/.config/cmux/agent-auth/<agent>`) ([`opted_in`]). Claude
//! then follows `claude_cloud_auth::team_pair`'s own rules (`joined_pair`: a pair or managed
//! credential the person set keeps own); Codex gets a provider of its own on the command line
//! ([`codex_args`]), since no cmux-generated `config.toml` is there.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cmux_vault_egress::{HostPattern, Secret, placeholder};
use zeroize::Zeroizing;

use crate::codex_cloud_auth::Inputs;

/// The egress proxy's built-in secret: this machine's credential.
pub(crate) const CREDENTIAL_NAME: &str = "CMUX_MACHINE_CREDENTIAL";
/// The header the hub's gateway route reads the machine credential from.
pub(crate) const HEADER: &str = "x-cmux-inference-authorization";
/// Codex's provider id for the hub's gateway route.
pub(crate) const CODEX_PROVIDER: &str = "cmux_hub";

/// The hub this machine joined, as the model plane uses it: an `https://` origin with a DNS host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Join {
    origin: String,
}

impl Join {
    /// The join of a record's `hub_origin`; None for a malformed, non-https or IP-literal origin.
    pub(crate) fn of(hub_origin: &str) -> Option<Join> {
        let origin = crate::cli::cloud_join::hub_origin(hub_origin).ok()?;
        HostPattern::parse(origin.strip_prefix("https://")?)?;
        Some(Join { origin })
    }

    /// `https://host[:port]`, no trailing slash.
    pub(crate) fn origin(&self) -> &str {
        &self.origin
    }

    /// `host[:port]`, the egress pattern's text and the lookup's target.
    pub(crate) fn host(&self) -> &str {
        self.origin.trim_start_matches("https://")
    }
}

/// This machine's join now: a live credential (not revoked, not copied from another box, `cmm_`,
/// for this hub: `cloud_join::read_join_credential`) and an `https://` hub origin. The value is
/// read and dropped; only [`secret_now`] keeps it, for the proxy.
pub(crate) fn now() -> Option<Join> {
    state().ok().flatten()
}

/// [`now`] with its reason: `Ok(None)` when this machine never joined (no machine record),
/// `Err` with the gate's own text when it joined but the join is unusable now (a record that
/// does not read, a bad hub origin, or `read_join_credential`'s revoked, cloned, other-hub or
/// malformed answer). A launch that opted in fails with that text rather than run own mode.
pub(crate) fn state() -> Result<Option<Join>, String> {
    let record = match crate::machine_record::load() {
        Ok(Some(record)) => record,
        Ok(None) => return Ok(None),
        Err(error) => return Err(format!("the machine credential does not read: {error:#}")),
    };
    let join = Join::of(&record.hub_origin).ok_or_else(|| {
        format!(
            "the joined hub origin {:?} is not an https origin with a DNS host",
            record.hub_origin
        )
    })?;
    let credential = Zeroizing::new(
        crate::cli::cloud_join::read_join_credential(join.origin())
            .map_err(|error| format!("{error:#}"))?,
    );
    drop(credential);
    Ok(Some(join))
}

/// The launch error of a Claude launch on a joined machine with no sign-in of its own, no
/// `CMUX_CLAUDE_AUTH` pin and no recorded choice: what is missing and the one fix. The choice
/// file is what `cr use team claude` writes on a Cloud machine; a joined machine has no `cr use`.
pub(crate) fn no_sign_in() -> String {
    let file = format!("~/{}/claude", crate::codex_cloud_auth::CHOICE_DIR);
    let dir = format!("~/{}", crate::codex_cloud_auth::CHOICE_DIR);
    format!(
        "This machine is joined to your team but has no Claude sign-in of its own and no choice \
recorded. To use your team's model route, run `mkdir -p {dir} && echo team > {file}` (what `cr \
use team claude` records on a cmux Cloud machine), or sign in to Claude here."
    )
}

/// The launch error of a launch that chose the team's route (`CMUX_<AGENT>_AUTH=team` or the
/// recorded choice `team`) on a joined machine whose route declined it, with `why`, the gate's
/// own text.
pub(crate) fn declined_text(agent: &str, why: &str) -> String {
    let upper = agent.to_ascii_uppercase();
    let file = format!("~/{}/{agent}", crate::codex_cloud_auth::CHOICE_DIR);
    format!(
        "This launch chose your team's model route (`team` in CMUX_{upper}_AUTH or {file}), but \
this joined machine cannot use it: {why}."
    )
}

/// The proxy's entry for `join`: `value` allowed only toward the hub origin's host.
pub(crate) fn secret(join: &Join, value: Zeroizing<String>) -> Option<Secret> {
    let host = HostPattern::parse(join.host())?;
    Some(Secret::new(CREDENTIAL_NAME, value, vec![host]))
}

/// The proxy's entry now ([`now`]'s rules), or None when the machine is not joined.
pub(crate) fn secret_now() -> Option<Secret> {
    let record = crate::machine_record::load().ok()??;
    let join = Join::of(&record.hub_origin)?;
    let value = Zeroizing::new(crate::cli::cloud_join::read_join_credential(join.origin()).ok()?);
    secret(&join, value)
}

/// Whether the launch opted in: `env_name` (`CMUX_CLAUDE_AUTH`, `CMUX_CODEX_AUTH`) pins `own` or
/// `team`, else `cr use`'s recorded choice for `agent`. No choice is own.
pub(crate) fn opted_in(inputs: &Inputs<'_>, env_name: &str, agent: &str) -> bool {
    match (inputs.var)(env_name).as_deref().map(str::trim) {
        Some("team") => true,
        Some("own") => false,
        _ => inputs.choice_for(agent) == Some("team"),
    }
}

/// [`opted_in`] before the launch's profile references are resolved: its profile env, then the
/// login env and this daemon's. A cheap check, so a launch that never opted in resolves nothing
/// twice.
pub(crate) fn may_opt_in(env: &BTreeMap<String, String>, env_name: &str, agent: &str) -> bool {
    let var = |k: &str| {
        env.get(k)
            .cloned()
            .or_else(|| crate::login_env::var(k))
            .or_else(|| std::env::var(k).ok())
            .filter(|v| !v.is_empty())
    };
    let home = var("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default();
    let inputs = Inputs { root: Path::new("/"), home: &home, var: &var, broker: false };
    opted_in(&inputs, env_name, agent)
}

/// The header's value as the agent holds it: the placeholder the proxy fills.
pub(crate) fn header_value() -> String {
    format!("Bearer {}", placeholder(CREDENTIAL_NAME))
}

/// Claude's `ANTHROPIC_CUSTOM_HEADERS` for a joined launch: `existing` without any line of
/// [`HEADER`], then that header. `claude_cloud_auth::apply_team` keeps it (an `x-cmux-` line).
pub(crate) fn claude_headers(existing: &str) -> String {
    let mut lines: Vec<&str> = existing
        .lines()
        .filter(|l| !l.trim().is_empty())
        .filter(|l| !l.trim_start().to_ascii_lowercase().starts_with(HEADER))
        .collect();
    let ours = format!("{HEADER}: {}", header_value());
    lines.push(&ours);
    lines.join("\n")
}

/// Whether a codex `argv` already picks its provider (`-c model_provider=...`): it keeps it.
pub(crate) fn names_provider(argv: &[String]) -> bool {
    argv.iter().any(|a| a.starts_with("model_provider="))
}

/// The `-c` overrides that point Codex at the hub's gateway route: a provider of its own with no
/// OpenAI sign-in and the placeholder header.
pub(crate) fn codex_args(join: &Join) -> Vec<String> {
    let p = format!("model_providers.{CODEX_PROVIDER}");
    let toml = |s: &str| serde_json::Value::String(s.to_owned()).to_string();
    let base = format!("{}/v1", join.origin());
    [
        format!("model_provider={}", toml(CODEX_PROVIDER)),
        format!("{p}.name={}", toml("cmux")),
        format!("{p}.base_url={}", toml(&base)),
        format!("{p}.wire_api={}", toml("responses")),
        format!("{p}.requires_openai_auth=false"),
        format!("{p}.http_headers={{ {} = {} }}", toml(HEADER), toml(&header_value())),
    ]
    .into_iter()
    .flat_map(|o| ["-c".to_owned(), o])
    .collect()
}

/// Put [`codex_args`] in a codex launch, after its own overrides (`codex_config_index`).
pub(crate) fn apply_codex(argv: &mut Vec<String>, join: &Join) {
    if argv.is_empty() {
        return;
    }
    let at = crate::agent_credentials::codex_config_index(argv);
    argv.splice(at..at, codex_args(join));
}

#[cfg(test)]
#[path = "joined_model_plane_tests.rs"]
mod tests;
