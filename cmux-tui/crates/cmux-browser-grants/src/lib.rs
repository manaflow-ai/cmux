//! Browser grants (RFD 0125 D7.2): an agent borrows the person's sign-in on
//! one site of one browser profile. A grant is a row in the home daemon
//! session (`browser_grants`, cmux-tui-core); a live row (not revoked, not
//! expired) is a lease. The browser host enforces the leases: an agent
//! session on the person's profile that holds any grant reaches only its
//! leased sites. A session with no grant keeps today's
//! `allowedDomains`/`prohibitedDomains` behaviour.
//!
//! This crate holds the rules both sides share, with no I/O: the site a
//! grant names (a registrable domain), the tiers and scopes, the default
//! 8 hour lease, and that commit is never remembered.

use std::fmt;

mod site;
pub use site::site_of;

/// How long a lease lasts when the grant names no expiry: "scoped to that
/// session, ending with it or after 8 hours" (D7.3).
pub const DEFAULT_LEASE_MS: u64 = 8 * 60 * 60 * 1000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrantError(pub String);

impl fmt::Display for GrantError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for GrantError {}

/// What the agent may do on the site. Ordered: a higher tier includes the
/// lower ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Tier {
    Read,
    Act,
    /// Purchase, send, delete, merge, publish: one approved action, never
    /// remembered (D7.4).
    Commit,
}

impl Tier {
    pub fn as_str(self) -> &'static str {
        match self {
            Tier::Read => "read",
            Tier::Act => "act",
            Tier::Commit => "commit",
        }
    }

    pub fn parse(text: &str) -> Result<Tier, GrantError> {
        match text {
            "read" => Ok(Tier::Read),
            "act" => Ok(Tier::Act),
            "commit" => Ok(Tier::Commit),
            other => Err(GrantError(format!("tier: expected read, act or commit, got {other:?}"))),
        }
    }
}

/// Who holds the grant.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum AgentScope {
    /// One agent session (the default: the chip's one click).
    #[default]
    Session,
    /// One agent identity, across its sessions.
    Agent,
    /// Every agent in one workspace ("Remember for this workspace").
    Workspace,
}

impl AgentScope {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentScope::Session => "session",
            AgentScope::Agent => "agent",
            AgentScope::Workspace => "workspace",
        }
    }

    pub fn parse(text: &str) -> Result<AgentScope, GrantError> {
        match text {
            "session" => Ok(AgentScope::Session),
            "agent" => Ok(AgentScope::Agent),
            "workspace" => Ok(AgentScope::Workspace),
            other => Err(GrantError(format!(
                "agent_scope: expected session, agent or workspace, got {other:?}"
            ))),
        }
    }
}

/// The site a grant names: the registrable domain of a host or URL
/// (`https://www.github.com/login` is `github.com`). Refuses wildcards, a
/// bare public suffix (`com`, `co.uk`, `github.io`) and anything that is
/// not a host.
pub fn grant_site(input: &str) -> Result<String, GrantError> {
    let refuse =
        || GrantError(format!("site: expected a domain such as github.com, got {input:?}"));
    let text = input.trim();
    let rest = text.split_once("://").map_or(text, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host_port = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = if host_port.starts_with('[') {
        host_port.split_inclusive(']').next().unwrap_or("")
    } else {
        host_port.split(':').next().unwrap_or("")
    };
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host.is_empty()
        || host.contains('*')
        || host.chars().any(|c| c.is_whitespace() || c.is_control())
        || host.starts_with('.')
    {
        return Err(refuse());
    }
    let site = site_of(&host);
    let ip = host.starts_with('[') || host.parse::<std::net::Ipv4Addr>().is_ok();
    if !ip
        && site != "localhost"
        && (!site.contains('.') || site::MULTI_SUFFIXES.contains(&site.as_str()))
    {
        return Err(GrantError(format!("site: {site:?} is a public suffix, not one site")));
    }
    Ok(site)
}

/// Whether a scope may hold a tier: commit is never remembered, so only
/// the session that met the action holds it.
pub fn check_scope(scope: AgentScope, tier: Tier) -> Result<(), GrantError> {
    if tier == Tier::Commit && scope != AgentScope::Session {
        return Err(GrantError(format!(
            "commit is never remembered: a commit grant is for one session, not a {}",
            scope.as_str()
        )));
    }
    Ok(())
}

/// When a grant made at `now_ms` ends: `requested`, or [`DEFAULT_LEASE_MS`]
/// from now. A session or commit grant lasts at most that long; a
/// requested expiry must be in the future.
pub fn expiry(
    scope: AgentScope,
    tier: Tier,
    now_ms: u64,
    requested: Option<u64>,
) -> Result<u64, GrantError> {
    let default = now_ms.saturating_add(DEFAULT_LEASE_MS);
    let Some(requested) = requested else {
        return Ok(default);
    };
    if requested <= now_ms {
        return Err(GrantError("expires_at: must be in the future".into()));
    }
    if (scope == AgentScope::Session || tier == Tier::Commit) && requested > default {
        return Err(GrantError(
            "expires_at: a session or commit grant lasts at most 8 hours".into(),
        ));
    }
    Ok(requested)
}

/// One live grant as the browser host enforces it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lease {
    pub site: String,
    pub tier: Tier,
    pub expires_at_ms: u64,
}

impl Lease {
    pub fn live_at(&self, now_ms: u64) -> bool {
        now_ms < self.expires_at_ms
    }
}

/// The leases of one agent session on one profile.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Leases(pub Vec<Lease>);

impl Leases {
    /// The strongest live lease covering `host`, if any.
    pub fn lease_for(&self, host: &str, now_ms: u64) -> Option<&Lease> {
        let site = site_of(host);
        self.0
            .iter()
            .filter(|lease| lease.site == site && lease.live_at(now_ms))
            .max_by_key(|lease| lease.tier)
    }

    /// Why `host` may not be reached, or `None` when a live lease covers it.
    pub fn refusal(&self, host: &str, now_ms: u64) -> Option<String> {
        if self.lease_for(host, now_ms).is_some() {
            return None;
        }
        Some(format!(
            "{} is not lent to this session (no live browser grant on the person's profile)",
            site_of(host)
        ))
    }

    /// The sites with a live lease, sorted, once each.
    pub fn live_sites(&self, now_ms: u64) -> Vec<String> {
        let mut sites: Vec<String> = self
            .0
            .iter()
            .filter(|lease| lease.live_at(now_ms))
            .map(|lease| lease.site.clone())
            .collect();
        sites.sort();
        sites.dedup();
        sites
    }
}

#[cfg(test)]
mod tests;
