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
pub use site::{normalize_host, site_of};

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
    if host.is_empty()
        || host.contains('*')
        || host.chars().any(|c| c.is_whitespace() || c.is_control())
        || host.starts_with('.')
    {
        return Err(refuse());
    }
    // The same spelling the browser host matches against (punycode, no
    // IPv6 brackets), so an accepted grant always matches its site.
    let host = normalize_host(host).ok_or_else(refuse)?;
    let ip = host.parse::<std::net::IpAddr>().is_ok();
    if !ip && host != "localhost" && (!host.contains('.') || site::is_public_suffix(&host)) {
        return Err(GrantError(format!("site: {host:?} is a public suffix, not one site")));
    }
    let site = site_of(&host);
    if !ip && site::is_public_suffix(&site) {
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

/// The browser profile agents use when they are signed in nowhere (the
/// browser host's agent profile).
pub const AGENTS_PROFILE: &str = "agent";

/// The profile an agent's browser tab opens in (D7.1): with
/// `browser.agents.openSignedOut` on, the Agents profile, signed out, so a
/// sign-in reaches it only through a grant; off (the default), the
/// workspace's profile, as before.
pub fn agent_tab_profile(open_signed_out: bool, workspace_profile: &str) -> &str {
    if open_signed_out { AGENTS_PROFILE } else { workspace_profile }
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
    fn covering(&self, site: String, now_ms: u64) -> impl Iterator<Item = &Lease> {
        // A stored row is matched in the same spelling as the host.
        self.0.iter().filter(move |lease| lease.live_at(now_ms) && site_of(&lease.site) == site)
    }

    /// The strongest live lease covering `host`, if any.
    pub fn lease_for(&self, host: &str, now_ms: u64) -> Option<&Lease> {
        self.covering(site_of(host), now_ms).max_by_key(|lease| lease.tier)
    }

    /// Why `host` may not be read (reached, observed, captured), or `None`
    /// when a live lease of any tier covers it.
    pub fn refusal(&self, host: &str, now_ms: u64) -> Option<String> {
        self.refusal_for(host, Tier::Read, now_ms)
    }

    /// Why an action that needs `needed` may not run on `host`, or `None`
    /// when a live lease of that tier or higher covers it.
    pub fn refusal_for(&self, host: &str, needed: Tier, now_ms: u64) -> Option<String> {
        let site = site_of(host);
        match self.lease_for(host, now_ms) {
            None => Some(format!(
                "{site} is not lent to this session (no live browser grant on the person's profile)"
            )),
            Some(lease) if lease.tier < needed => Some(format!(
                "{site} is lent to this session for {} only; this needs a {} grant",
                lease.tier.as_str(),
                needed.as_str()
            )),
            Some(_) => None,
        }
    }

    /// Allows one action that needs `needed` on `host`: `Ok(None)` when a
    /// lease below commit covers it, `Ok(Some(lease))` when only a commit
    /// lease does (that lease is spent by this one approved action and
    /// removed: commit is never remembered, D7.4), or why not.
    pub fn authorize(
        &mut self,
        host: &str,
        needed: Tier,
        now_ms: u64,
    ) -> Result<Option<Lease>, String> {
        if let Some(reason) = self.refusal_for(host, needed, now_ms) {
            return Err(reason);
        }
        let site = site_of(host);
        let lasting = self
            .covering(site.clone(), now_ms)
            .any(|lease| lease.tier != Tier::Commit && lease.tier >= needed);
        if lasting || needed == Tier::Read {
            return Ok(None);
        }
        let spent = self.0.iter().position(|lease| {
            lease.tier == Tier::Commit && lease.live_at(now_ms) && site_of(&lease.site) == site
        });
        Ok(spent.map(|index| self.0.remove(index)))
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
