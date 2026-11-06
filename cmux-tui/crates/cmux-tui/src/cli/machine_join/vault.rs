//! `cmux machine vault set|policy|ls|rm|grant|revoke`: the person's vault on the cmux
//! platform, the env vars and API keys a machine of theirs gets when it joins
//! with `cmux machine add --vault` (or is granted it later).
//!
//! - `set NAME`: the value comes from a no-echo prompt on a terminal, else
//!   stdin (never argv), and goes to `PUT /v1/vault/env/NAME` as
//!   `{valueBase64, fingerprint}`; nothing prints it. With `--host H`, `--no-hosts`
//!   or `--env` it also sends `{delivery, allowedHosts}` (see [`policy`]); without
//!   them the platform keeps the entry's policy (or picks the default of a new one).
//! - `policy NAME (--host H... | --no-hosts | --env)`: `PUT /v1/vault/env/NAME/policy`,
//!   which changes no value and no revision.
//! - `ls`: `GET /v1/vault/env`, names, revisions, times and delivery policy only
//!   (any other field of the answer is dropped, never printed).
//! - `rm NAME`: `DELETE /v1/vault/env/NAME`.
//! - `grant|revoke MACHINE`: `PUT /v1/machines/:id/vault {granted}`.
//!
//! The vault never holds a Claude or Codex sign-in: those are the person's to
//! make on each machine, through the vendor's own flow.
//!
//! Not `cmux vault`: that noun is the Credential Vault's (cmux#26487).

use std::io::Write;

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::{CallError, Failure, Hooks, Platform, clean, find};
use crate::cli::{OutputMode, UsageError};

mod policy;

pub(in crate::cli) use policy::Policy;

const USAGE: &str = "usage: cmux machine vault set NAME [--host H]... [--no-hosts | --env]   (the value from a hidden prompt or stdin)
       cmux machine vault policy NAME (--host H... | --no-hosts | --env)
       cmux machine vault ls
  --host H     agents get a placeholder; the machine sends the real value only to H (repeat for more)
  --no-hosts   agents get a placeholder that is never replaced
  --env        agents get the real value in their env (weaker: agents can read the value)
       cmux machine vault rm NAME
       cmux machine vault grant|revoke MACHINE
  each takes --platform URL and --cloud-token-file PATH, --cloud-token-stdin or CMUX_CLOUD_ACCESS_TOKEN.";

const ENV_PATH: &str = "/v1/vault/env";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum VaultVerb {
    Set { name: String, policy: Option<Policy> },
    Policy { name: String, policy: Policy },
    Ls,
    Rm { name: String },
    Grant { machine: String, granted: bool },
}

/// `machine vault <words>`.
pub(super) fn parse(rest: &[String]) -> Result<super::Command, UsageError> {
    let usage = || UsageError::new(USAGE);
    let mut auth = super::Auth::default();
    let mut flags = policy::PolicyFlags::default();
    let mut policy_flag = false;
    let mut positional = Vec::new();
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        let Some(flag) = word.strip_prefix("--") else {
            positional.push(word.clone());
            continue;
        };
        let (flag, inline) = match flag.split_once('=') {
            Some((flag, value)) => (flag, Some(value.to_owned())),
            None => (flag, None),
        };
        let mut next = || words.next().cloned();
        if flags.take(flag, inline.clone(), &mut next)? {
            policy_flag = true;
            continue;
        }
        match flag {
            "platform" | "cloud-token-file" => {
                let value = match inline {
                    Some(value) => value,
                    None => words
                        .next()
                        .cloned()
                        .ok_or_else(|| UsageError::new(format!("--{flag} needs a value")))?,
                };
                if flag == "platform" {
                    auth.platform = Some(value);
                } else {
                    auth.token_file = Some(value.into());
                }
            }
            "cloud-token-stdin" if inline.is_none() => auth.token_stdin = true,
            _ => return Err(usage()),
        }
    }
    if auth.token_stdin && auth.token_file.is_some() {
        return Err(UsageError::new(
            "give the credential one way: --cloud-token-file or --cloud-token-stdin",
        ));
    }
    let policy = flags.policy()?;
    let verb = match positional.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["set", name] => VaultVerb::Set { name: checked_name(name)?, policy },
        ["policy", name] => VaultVerb::Policy {
            name: checked_name(name)?,
            policy: policy.ok_or_else(|| {
                UsageError::new(
                    "vault policy takes --host H (repeatable), --no-hosts or --env (weaker: agents can read the value)",
                )
            })?,
        },
        _ if policy_flag && !matches!(positional.first().map(String::as_str), Some("set")) => {
            return Err(UsageError::new("--host, --no-hosts and --env go with vault set or vault policy"));
        }
        ["ls" | "list"] => VaultVerb::Ls,
        ["rm" | "remove", name] => VaultVerb::Rm { name: checked_name(name)? },
        ["grant", machine] => VaultVerb::Grant { machine: (*machine).to_owned(), granted: true },
        ["revoke", machine] => VaultVerb::Grant { machine: (*machine).to_owned(), granted: false },
        // A value after the name would be in argv for every process to read.
        ["set", _, _, ..] => {
            return Err(UsageError::new(
                "vault set takes the value from a hidden prompt or stdin, never the command line",
            ));
        }
        _ => return Err(usage()),
    };
    if matches!(verb, VaultVerb::Set { .. }) && auth.token_stdin {
        return Err(UsageError::new(
            "vault set reads its value from stdin: give the credential with --cloud-token-file or CMUX_CLOUD_ACCESS_TOKEN",
        ));
    }
    Ok(super::Command { verb: super::Verb::Vault(verb), auth })
}

/// API keys the vault exists to carry, which Cloud secrets keep for the model plane: a joined
/// Mac of the person's own has no model plane to collide with.
const PROVIDER_KEYS: [&str; 5] = [
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_AUTH_TOKEN",
];

/// Whether `name` is a vault var name: [`PROVIDER_KEYS`], else the Cloud secrets' rules
/// (`[A-Za-z_][A-Za-z0-9_]*`, at most 128, not one the machine's shell or cmux owns).
pub(super) fn vault_name_ok(name: &str) -> bool {
    PROVIDER_KEYS.contains(&name) || crate::cli::cloud_secret::check_name(name).is_ok()
}

fn checked_name(name: &str) -> Result<String, UsageError> {
    Some(name).filter(|n| vault_name_ok(n)).map(str::to_owned).ok_or_else(|| {
        UsageError::new(format!(
            "{:?} is not an env var name: [A-Za-z_][A-Za-z0-9_]*, and not PATH, HOME, LD_*, CMUX_* or another the machine owns",
            clean(name)
        ))
    })
}

/// The failure for a vault call; a 404 on the list means the vault is off on this server.
fn vault_failure(error: &CallError, what: &str) -> Failure {
    match error {
        CallError::Status { status: 404, .. } => Failure::new(
            "machine_vault.unavailable",
            "the vault isn't available on this server yet (it answered 404)",
        ),
        CallError::Status { status: 413, .. }
        | CallError::Status { code: "vault.too_large", .. } => {
            Failure::new("machine_vault.too_large", "the platform refused the value: too large")
        }
        CallError::Status { code: "vault.invalid_hosts", .. } => Failure::new(
            "machine_vault.invalid_hosts",
            "the platform refused the hosts: give DNS names like api.github.com or *.example.com",
        ),
        error => error.failure(what),
    }
}

/// One listed var, as printed: never anything but its name, revision, time and policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Entry {
    pub name: String,
    pub revision: Option<u64>,
    pub updated_at: Value,
    pub policy: Policy,
}

/// The vars of a `GET /v1/vault/env` answer; entries without a usable name are skipped.
pub(super) fn entries(body: &Value) -> Option<Vec<Entry>> {
    let rows = body.get("entries")?.as_array()?;
    Some(
        rows.iter()
            .filter_map(|row| {
                let name = row.get("name")?.as_str()?;
                vault_name_ok(name).then_some(())?;
                let updated_at = match row.get("updatedAt") {
                    Some(Value::String(text)) => Value::String(clean(text)),
                    Some(Value::Number(n)) => Value::Number(n.clone()),
                    _ => Value::Null,
                };
                Some(Entry {
                    name: name.to_owned(),
                    revision: row.get("revision").and_then(Value::as_u64),
                    updated_at,
                    policy: Policy::from_answer(row),
                })
            })
            .collect(),
    )
}

/// The names of the person's vault vars (`machine add --vault`'s consent).
pub(super) fn env_names(platform: &Platform) -> Result<Vec<String>, Failure> {
    let body = platform
        .request(reqwest::Method::GET, ENV_PATH, None)
        .map_err(|e| vault_failure(&e, "the vault list"))?;
    let rows = entries(&body).ok_or_else(|| {
        Failure::new("machine_vault.unreadable", "the cmux platform's vault list is unreadable")
    })?;
    Ok(rows.into_iter().map(|e| e.name).collect())
}

/// The question `machine add --vault` asks before it makes a line.
pub(super) fn consent_text(names: &[String]) -> String {
    match names {
        [] => "This machine gets your vault (it has no env vars yet; ones you add later reach it too). Continue?".to_owned(),
        [one] => format!("This machine gets 1 env var from your vault: {one}. Continue?"),
        many => format!(
            "This machine gets {} env vars from your vault: {}. Continue?",
            many.len(),
            many.join(", ")
        ),
    }
}

/// sha256 hex of the value's bytes.
fn fingerprint(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

pub(super) fn run(
    verb: &VaultVerb,
    platform: &Platform,
    output: OutputMode,
    out: &mut dyn Write,
    hooks: &mut Hooks<'_>,
) -> Result<i32, Failure> {
    let io = |e: std::io::Error| Failure::new("io", e.to_string());
    let (human, value) = match verb {
        VaultVerb::Set { name, policy } => {
            let value = (hooks.read_value)(name)
                .map_err(|_| Failure::usage(format!("the value for {name} could not be read")))?;
            if value.is_empty() {
                return Err(Failure::usage(format!("the value for {name} is empty")));
            }
            if value.contains('\0') {
                return Err(Failure::usage(format!("the value for {name} has a NUL byte")));
            }
            let mut body = json!({
                "valueBase64": base64::engine::general_purpose::STANDARD.encode(value.as_bytes()),
                "fingerprint": fingerprint(value.as_bytes()),
            });
            drop(value);
            if let (Some(policy), Some(fields)) = (policy, body.as_object_mut()) {
                fields.insert("delivery".into(), policy.delivery.wire().into());
                fields.insert("allowedHosts".into(), json!(policy.allowed_hosts));
            }
            let answer = platform
                .request(reqwest::Method::PUT, &format!("{ENV_PATH}/{name}"), Some(body))
                .map_err(|e| vault_failure(&e, "the value"))?;
            let revision = answer.get("revision").and_then(Value::as_u64);
            let mut human = match revision {
                Some(revision) => format!("{name} saved to your vault (revision {revision})."),
                None => format!("{name} saved to your vault."),
            };
            let mut value = json!({ "name": name, "revision": revision });
            if let Some(policy) = policy {
                human = format!("{human}\nDelivery: {}", policy.label());
                if let Some(fields) = value.as_object_mut() {
                    fields.insert("delivery".into(), policy.delivery.wire().into());
                    fields.insert("allowedHosts".into(), json!(policy.allowed_hosts));
                }
            }
            (human, value)
        }
        VaultVerb::Policy { name, policy } => {
            let answer = platform
                .request(
                    reqwest::Method::PUT,
                    &format!("{ENV_PATH}/{name}/policy"),
                    Some(policy.wire()),
                )
                .map_err(|e| match e {
                    CallError::Status { code: "vault.no_entry" | "vault.not_found", .. } => {
                        Failure::new("machine_vault.not_found", format!("your vault has no {name}"))
                    }
                    e => vault_failure(&e, "the policy"),
                })?;
            // What the platform stored; an answer without a policy is what was sent.
            let stored = if answer.get("delivery").is_some() {
                Policy::from_answer(&answer)
            } else {
                policy.clone()
            };
            let revision = answer.get("revision").and_then(Value::as_u64);
            (
                format!("{name}: {}", stored.label()),
                json!({
                    "name": name,
                    "revision": revision,
                    "delivery": stored.delivery.wire(),
                    "allowedHosts": stored.allowed_hosts,
                }),
            )
        }
        VaultVerb::Ls => {
            let body = platform
                .request(reqwest::Method::GET, ENV_PATH, None)
                .map_err(|e| vault_failure(&e, "the vault list"))?;
            let rows = entries(&body).ok_or_else(|| {
                Failure::new(
                    "machine_vault.unreadable",
                    "the cmux platform's vault list is unreadable",
                )
            })?;
            let human = if rows.is_empty() {
                "Your vault has no env vars. Add one: cmux machine vault set NAME".to_owned()
            } else {
                rows.iter()
                    .map(|e| {
                        let revision = e.revision.map_or_else(String::new, |r| format!("  r{r}"));
                        let at =
                            e.updated_at.as_str().map_or_else(String::new, |t| format!("  {t}"));
                        format!("{}{revision}{at}  {}", e.name, e.policy.label())
                    })
                    .collect::<Vec<_>>()
                    .join("\n")
            };
            let value: Vec<Value> = rows
                .iter()
                .map(|e| {
                    json!({
                        "name": e.name,
                        "revision": e.revision,
                        "updatedAt": e.updated_at,
                        "delivery": e.policy.delivery.wire(),
                        "allowedHosts": e.policy.allowed_hosts,
                    })
                })
                .collect();
            (human, json!({ "entries": value }))
        }
        VaultVerb::Rm { name } => {
            platform
                .request(reqwest::Method::DELETE, &format!("{ENV_PATH}/{name}"), None)
                .map_err(|e| match e {
                    CallError::Status { status: 404, code: "vault.not_found" | "not_found" } => {
                        Failure::new("machine_vault.not_found", format!("your vault has no {name}"))
                    }
                    e => vault_failure(&e, "the removal"),
                })?;
            (
                format!(
                    "{name} removed from your vault. Machines that pulled it keep their copy until they pull again."
                ),
                json!({ "name": name, "removed": true }),
            )
        }
        VaultVerb::Grant { machine, granted } => {
            let listed = platform.credentials().map_err(|e| e.failure("the machine list"))?;
            let found = find(&listed, machine)?;
            let path = format!("/v1/machines/{}/vault", found.machine_id);
            platform
                .request(reqwest::Method::PUT, &path, Some(json!({ "granted": granted })))
                .map_err(|e| match e {
                    CallError::Status { status: 403, code: "machine.vault_personal_only" } => {
                        Failure::new(
                            "machine_join.vault_personal_only",
                            "the vault goes only to machines of your personal team",
                        )
                    }
                    e => vault_failure(&e, "the grant"),
                })?;
            let human = if *granted {
                format!(
                    "{} may pull your vault now (it does on its next `acpmux host vault pull`).",
                    found.name
                )
            } else {
                format!(
                    "{} may no longer pull your vault. What it already pulled stays on it.",
                    found.name
                )
            };
            (
                human,
                json!({ "machineId": found.machine_id, "name": found.name, "granted": granted }),
            )
        }
    };
    match output {
        OutputMode::Human => writeln!(out, "{human}").map_err(io)?,
        OutputMode::Json | OutputMode::JsonLines => writeln!(out, "{value}").map_err(io)?,
        OutputMode::Quiet => {}
    }
    Ok(0)
}

#[cfg(test)]
mod tests;
