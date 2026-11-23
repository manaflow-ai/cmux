//! What a GitHub refusal's code says about the team's link to the cmux GitHub App, parsed once
//! (plans/cmux-next/cloud-integrations-state-machine.md §1). `needs_reauth` is the connection's own
//! `ConnectionStatus` (the platform's protocol `integrations.ts`, `cmux_cloud_wire::ConnectionStatus`)
//! answered as the error code; the other codes are the API's and the agent's. Every reader (the
//! machine's `cmux github` helper and gh shim, acpmux's GitHub MCP and App token errors, the repo
//! listing) matches this enum, never the strings.

use cmux_cloud_wire::ConnectionStatus;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GithubLink {
    /// `integration.not_found`: the team has no usable connection.
    NotFound,
    /// `github.not_connected`: the agent's reason for the same, passed on by its socket.
    NotConnected,
    /// `needs_reauth`: linked, but GitHub no longer honors it (suspended, uninstalled, a mint's
    /// 401/404).
    NeedsReauth,
    /// `policy.denied`: the connection does not cover the repository, or the team's policy refuses
    /// it.
    PolicyDenied,
}

impl GithubLink {
    /// Every variant, for the exhaustive tests.
    pub const ALL: [Self; 4] =
        [Self::NotFound, Self::NotConnected, Self::NeedsReauth, Self::PolicyDenied];

    /// The link a refusal `code` names; `None` for any other code (an outage, a bad answer, a
    /// sign-in), which each reader handles on its own.
    pub fn of(code: &str) -> Option<Self> {
        match code {
            "integration.not_found" => Some(Self::NotFound),
            "github.not_connected" => Some(Self::NotConnected),
            "policy.denied" => Some(Self::PolicyDenied),
            other => match ConnectionStatus::from_wire(other) {
                ConnectionStatus::NeedsReauth => Some(Self::NeedsReauth),
                ConnectionStatus::Pending
                | ConnectionStatus::Active
                | ConnectionStatus::Error
                | ConnectionStatus::Revoked
                | ConnectionStatus::Expired
                | ConnectionStatus::Unknown(_) => None,
            },
        }
    }

    /// The wire code.
    pub fn code(self) -> &'static str {
        match self {
            Self::NotFound => "integration.not_found",
            Self::NotConnected => "github.not_connected",
            Self::NeedsReauth => "needs_reauth",
            Self::PolicyDenied => "policy.denied",
        }
    }

    /// Whether connecting GitHub (again) is the fix and the same ask then succeeds: no link, or
    /// one to renew. A repository the link does not cover is granted on GitHub's page instead.
    pub fn unlinked(self) -> bool {
        match self {
            Self::NotFound | Self::NotConnected | Self::NeedsReauth => true,
            Self::PolicyDenied => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_link_parses_from_its_own_code_and_needs_reauth_is_the_connection_status() {
        for link in GithubLink::ALL {
            assert_eq!(GithubLink::of(link.code()), Some(link));
        }
        assert_eq!(GithubLink::NeedsReauth.code(), ConnectionStatus::NeedsReauth.as_str());
        // No other connection status is a refusal code, and nothing else parses.
        for status in ConnectionStatus::KNOWN.iter().filter(|s| **s != "needs_reauth") {
            assert_eq!(GithubLink::of(status), None, "{status}");
        }
        for other in [
            "",
            "unknown",
            "rate_limited",
            "busy",
            "auth.required",
            "Needs_Reauth",
            "needs_reauth ",
        ] {
            assert_eq!(GithubLink::of(other), None, "{other:?}");
        }
    }

    #[test]
    fn only_a_missing_or_stale_link_is_fixed_by_connecting() {
        let unlinked: Vec<_> = GithubLink::ALL.into_iter().filter(|l| l.unlinked()).collect();
        assert_eq!(
            unlinked,
            [GithubLink::NotFound, GithubLink::NotConnected, GithubLink::NeedsReauth]
        );
    }
}
