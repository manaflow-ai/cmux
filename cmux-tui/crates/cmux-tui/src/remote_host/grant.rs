//! Teammate grants (plans/cmux-next/teammate-access-DESIGN.md 4-5): scoped
//! access a teammate gives one allowlisted login, only after they approve it
//! at a terminal on their own machine.

use serde::{Deserialize, Serialize};

use super::config::{Config, same_login};

/// The only logins a teammate grant may name. A grant for any other login is
/// refused when it is made and ignored when a peer connects. Changing this
/// list is a reviewed code change, never a setting.
pub(crate) const TEAMMATE_ALLOWLIST: &[&str] = &["lawrence@manaflow.ai"];

/// What a teammate grant lets the grantee do.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Scope {
    /// The read-only probe: host name, OS, version, session, access.
    Status,
    /// Attach to shared agent chats through the filtered proxy.
    Agents,
    /// A full daemon connection: terminals and input, as the teammate.
    Shell,
}

impl Scope {
    pub(crate) fn parse(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "status" => Some(Self::Status),
            "agents" => Some(Self::Agents),
            "shell" => Some(Self::Shell),
            _ => None,
        }
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::Agents => "agents",
            Self::Shell => "shell",
        }
    }

    fn describe(self) -> &'static str {
        match self {
            Self::Status => "see this machine's cmux status (read-only)",
            Self::Agents => crate::localization::catalog().host_share.agents,
            Self::Shell => {
                "open your cmux terminals and run any command as you (full shell access)"
            }
        }
    }
}

/// One teammate grant in the host config.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Grant {
    pub login: String,
    pub scopes: Vec<Scope>,
    /// When the teammate approved it; `None` is a grant not yet approved.
    #[serde(default)]
    pub consented_at: Option<String>,
    /// How it was approved (`cli-tty`, later `app`).
    #[serde(default)]
    pub consented_via: Option<String>,
    #[serde(default)]
    pub revoked_at: Option<String>,
}

/// Records `login`'s approved grant of `scopes`, replacing any earlier one. The write goes
/// through `config::commit`, which closes the open connections admitted under the old grant.
pub(crate) fn replace(config: &mut Config, login: &str, scopes: Vec<Scope>) {
    config.grants.retain(|g| !same_login(&g.login, login));
    config.grants.push(Grant {
        login: login.to_owned(),
        scopes,
        consented_at: Some(now_rfc3339()),
        consented_via: Some("cli-tty".to_owned()),
        revoked_at: None,
    });
}

pub(crate) fn on_allowlist(login: &str) -> bool {
    TEAMMATE_ALLOWLIST.iter().any(|allowed| same_login(allowed, login))
}

/// The grant that applies to `login`, as admission sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Check {
    Granted(Vec<Scope>),
    Refused(&'static str),
}

pub(crate) fn check(config: &Config, login: &str) -> Check {
    let Some(grant) = config.grants.iter().find(|g| same_login(&g.login, login)) else {
        return Check::Refused("login is neither the owner nor allowed");
    };
    if !config.teammate_access {
        return Check::Refused("teammate access is off on this machine");
    }
    if !on_allowlist(login) {
        return Check::Refused("login is not on the teammate allowlist");
    }
    if grant.revoked_at.is_some() {
        return Check::Refused("teammate access was revoked on this machine");
    }
    if grant.consented_at.is_none() {
        return Check::Refused("teammate access is waiting for approval on this machine");
    }
    let mut scopes = grant.scopes.clone();
    scopes.sort();
    scopes.dedup();
    if scopes.is_empty() {
        return Check::Refused("teammate grant has no scopes");
    }
    Check::Granted(scopes)
}

/// Whether the scopes allow a connection; agents use the filtered proxy.
pub(crate) fn may_connect(scopes: &[Scope]) -> bool {
    scopes.contains(&Scope::Shell) || scopes.contains(&Scope::Agents)
}

/// A grant needs a person: stdin and stderr must both be terminals, so no
/// script, installer or update can approve access.
pub(crate) fn require_interactive(stdin_tty: bool, stderr_tty: bool) -> anyhow::Result<()> {
    if stdin_tty && stderr_tty {
        Ok(())
    } else {
        anyhow::bail!(
            "teammate access must be approved by a person at a terminal on this machine (no script, pipe or update can grant it)"
        )
    }
}

/// Only the full word `yes` approves.
pub(crate) fn confirmed(answer: &str) -> bool {
    answer.trim().eq_ignore_ascii_case("yes")
}

/// The text shown before the teammate approves.
pub(crate) fn consent_text(login: &str, scopes: &[Scope]) -> String {
    let mut text = format!("{login} will be able to, from their own tailnet devices:\n");
    for scope in scopes {
        text.push_str(&format!("  - {}\n", scope.describe()));
    }
    if scopes.contains(&Scope::Shell) {
        text.push_str(
            "\nWARNING: shell access lets them run any command on this machine as you.\n",
        );
    }
    text.push_str(&format!(
        "\nOnly over your tailnet; nothing listens on other networks.\n\
         Every connection is written to the audit log on this machine.\n\
         To revoke at any time: cmux host revoke {login}\n"
    ));
    text
}

/// Seconds since the Unix epoch as RFC 3339 UTC (`2026-10-20T09:00:00Z`).
pub(crate) fn now_rfc3339() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or_default();
    rfc3339(secs)
}

fn rfc3339(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // Civil date from days since 1970-01-01 (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        rem / 3_600,
        (rem / 60) % 60,
        rem % 60
    )
}

#[cfg(test)]
mod tests {
    #[test]
    fn rfc3339_formats_known_instants() {
        assert_eq!(super::rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(super::rfc3339(1_792_488_779), "2026-10-20T09:32:59Z");
        assert_eq!(super::rfc3339(951_782_400), "2000-02-29T00:00:00Z");
    }
}
