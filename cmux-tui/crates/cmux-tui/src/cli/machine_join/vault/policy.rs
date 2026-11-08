//! A vault entry's delivery policy: how a machine hands the value to its agents.
//!
//! - `proxy` (the default): agents get the placeholder `cmux-secret://NAME`, and the
//!   machine's egress proxy puts the real value in request headers only on a connection to
//!   one of the entry's allowed hosts.
//! - `env`: the real value in the agents' environment, as before. Any agent can read it
//!   and send it anywhere, so the CLI always labels it weaker.

use serde_json::{Value, json};

use crate::cli::UsageError;

/// At most this many allowed hosts per entry (the platform's limit).
pub(super) const MAX_HOSTS: usize = 16;

/// A lowercase DNS name, optionally `*.` (subdomains only) and `:port`; no scheme, path,
/// IP literal, userinfo or trailing dot. The platform validates with the pattern
/// `^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}(:[1-9][0-9]{0,4})?$`;
/// this checks the same by hand, so no pattern build can fail at run time (the tests hold
/// the two equal): one or more labels and a last label, each 1 to 63 of `a-z`, `0-9` and
/// `-`; a label neither starts nor ends with `-`, the last label starts with `a-z`; a port
/// is 1 to 5 digits with no leading zero.
pub(super) fn host_pattern_ok(host: &str) -> bool {
    let (name, port) = match host.split_once(':') {
        Some((name, port)) => (name, Some(port)),
        None => (host, None),
    };
    if let Some(port) = port
        && !((1..=5).contains(&port.len())
            && !port.starts_with('0')
            && port.bytes().all(|b| b.is_ascii_digit()))
    {
        return false;
    }
    let name = name.strip_prefix("*.").unwrap_or(name);
    let Some((labels, last)) = name.rsplit_once('.') else {
        return false;
    };
    labels.split('.').all(label_ok)
        && last.starts_with(|c: char| c.is_ascii_lowercase())
        && label_chars_ok(last)
}

/// `[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?`
fn label_ok(label: &str) -> bool {
    label_chars_ok(label) && !label.starts_with('-') && !label.ends_with('-')
}

/// `[a-z0-9-]{1,63}`
fn label_chars_ok(label: &str) -> bool {
    (1..=63).contains(&label.len())
        && label.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// Whether `host` is an allowed-host pattern the platform accepts.
pub(super) fn host_ok(host: &str) -> bool {
    host.len() <= 260
        && host_pattern_ok(host)
        && host
            .rsplit_once(':')
            .is_none_or(|(_, port)| port.parse::<u32>().is_ok_and(|p| p <= 65535))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(in crate::cli) enum Delivery {
    Proxy,
    Env,
}

impl Delivery {
    pub(super) fn wire(self) -> &'static str {
        match self {
            Self::Proxy => "proxy",
            Self::Env => "env",
        }
    }

    /// The answer's `delivery`. A hub that sends none predates the egress proxy and puts
    /// the value in the agents' env, so a missing one reads as `env`.
    fn from_answer(row: &Value) -> Option<Self> {
        match row.get("delivery") {
            None | Some(Value::Null) => Some(Self::Env),
            Some(Value::String(text)) if text == "proxy" => Some(Self::Proxy),
            Some(Value::String(text)) if text == "env" => Some(Self::Env),
            Some(_) => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct Policy {
    pub delivery: Delivery,
    pub allowed_hosts: Vec<String>,
}

impl Policy {
    /// The policy of a `GET /v1/vault/env` row (or a policy answer); hosts the platform
    /// should never have stored are dropped, never printed.
    pub(super) fn from_answer(row: &Value) -> Self {
        let delivery = Delivery::from_answer(row).unwrap_or(Delivery::Env);
        let allowed_hosts = row
            .get("allowedHosts")
            .and_then(Value::as_array)
            .map(|hosts| {
                hosts
                    .iter()
                    .filter_map(Value::as_str)
                    .filter(|h| host_ok(h))
                    .take(MAX_HOSTS)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        Self { delivery, allowed_hosts }
    }

    /// `{delivery, allowedHosts}`, as the platform takes and gives them.
    pub(super) fn wire(&self) -> Value {
        json!({ "delivery": self.delivery.wire(), "allowedHosts": self.allowed_hosts })
    }

    /// How a person reads it.
    pub(super) fn label(&self) -> String {
        match self.delivery {
            Delivery::Env => "env (weaker: agents can read the value)".to_owned(),
            Delivery::Proxy if self.allowed_hosts.is_empty() => {
                "proxy: no hosts (placeholder only)".to_owned()
            }
            Delivery::Proxy => format!("proxy: {}", self.allowed_hosts.join(", ")),
        }
    }
}

/// The policy flags of `set` and `policy`: `--host H` (repeatable), `--no-hosts`, `--env`.
#[derive(Debug, Default)]
pub(super) struct PolicyFlags {
    hosts: Vec<String>,
    no_hosts: bool,
    env: bool,
}

impl PolicyFlags {
    /// Takes `flag` if it is a policy flag; `Ok(false)` leaves it to the caller.
    pub(super) fn take(
        &mut self,
        flag: &str,
        inline: Option<String>,
        next: &mut dyn FnMut() -> Option<String>,
    ) -> Result<bool, UsageError> {
        match flag {
            "host" => {
                let value = match inline {
                    Some(value) => value,
                    None => next().ok_or_else(|| UsageError::new("--host needs a value"))?,
                };
                let host = value.trim().to_ascii_lowercase();
                if !host_ok(&host) {
                    return Err(UsageError::new(format!(
                        "{:?} is not a host: a DNS name like api.github.com, *.example.com or host:8443 (no scheme, path or IP)",
                        super::clean(&value)
                    )));
                }
                if !self.hosts.contains(&host) {
                    self.hosts.push(host);
                }
                Ok(true)
            }
            "no-hosts" if inline.is_none() => {
                self.no_hosts = true;
                Ok(true)
            }
            "env" if inline.is_none() => {
                self.env = true;
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    /// The policy the flags give, or `None` when none was given.
    pub(super) fn policy(self) -> Result<Option<Policy>, UsageError> {
        if self.env && (self.no_hosts || !self.hosts.is_empty()) {
            return Err(UsageError::new(
                "--env puts the real value in the agents' env, where no host limit applies: give --env or --host, not both",
            ));
        }
        if self.no_hosts && !self.hosts.is_empty() {
            return Err(UsageError::new("give --host or --no-hosts, not both"));
        }
        if self.hosts.len() > MAX_HOSTS {
            return Err(UsageError::new(format!("at most {MAX_HOSTS} hosts per env var")));
        }
        Ok(if self.env {
            Some(Policy { delivery: Delivery::Env, allowed_hosts: Vec::new() })
        } else if self.no_hosts || !self.hosts.is_empty() {
            Some(Policy { delivery: Delivery::Proxy, allowed_hosts: self.hosts })
        } else {
            None
        })
    }
}
