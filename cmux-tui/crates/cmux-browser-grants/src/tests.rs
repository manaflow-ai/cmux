use super::*;

const NOW: u64 = 1_800_000_000_000;

#[test]
fn a_grant_names_the_registrable_domain() {
    assert_eq!(grant_site("github.com").unwrap(), "github.com");
    assert_eq!(grant_site("https://www.GitHub.com/login?x=1").unwrap(), "github.com");
    assert_eq!(grant_site("user@gist.github.com:443").unwrap(), "github.com");
    assert_eq!(grant_site("bbc.co.uk.").unwrap(), "bbc.co.uk");
    assert_eq!(grant_site("me.github.io").unwrap(), "me.github.io");
    assert_eq!(grant_site("localhost:3000").unwrap(), "localhost");
    assert_eq!(grant_site("127.0.0.1").unwrap(), "127.0.0.1");
    for bad in ["", "  ", "*.github.com", "com", "co.uk", "github.io", "https:///x", ".com"] {
        assert!(grant_site(bad).is_err(), "{bad:?} should be refused");
    }
}

#[test]
fn commit_is_never_remembered() {
    assert!(check_scope(AgentScope::Session, Tier::Commit).is_ok());
    assert!(check_scope(AgentScope::Workspace, Tier::Commit).is_err());
    assert!(check_scope(AgentScope::Agent, Tier::Commit).is_err());
    for tier in [Tier::Read, Tier::Act] {
        for scope in [AgentScope::Session, AgentScope::Agent, AgentScope::Workspace] {
            assert!(check_scope(scope, tier).is_ok());
        }
    }
}

#[test]
fn a_lease_lasts_eight_hours_by_default() {
    assert_eq!(AgentScope::default(), AgentScope::Session);
    assert_eq!(expiry(AgentScope::Session, Tier::Read, NOW, None).unwrap(), NOW + DEFAULT_LEASE_MS);
    assert_eq!(expiry(AgentScope::Session, Tier::Act, NOW, Some(NOW + 1)).unwrap(), NOW + 1);
    assert!(expiry(AgentScope::Session, Tier::Act, NOW, Some(NOW)).is_err());
    assert!(
        expiry(AgentScope::Session, Tier::Read, NOW, Some(NOW + DEFAULT_LEASE_MS + 1)).is_err()
    );
    assert!(
        expiry(AgentScope::Workspace, Tier::Act, NOW, Some(NOW + DEFAULT_LEASE_MS * 30)).is_ok()
    );
}

#[test]
fn leases_cover_only_live_leased_sites() {
    let leases = Leases(vec![
        Lease { site: "github.com".into(), tier: Tier::Read, expires_at_ms: NOW + 10 },
        Lease { site: "github.com".into(), tier: Tier::Act, expires_at_ms: NOW + 5 },
        Lease { site: "linear.app".into(), tier: Tier::Read, expires_at_ms: NOW - 1 },
    ]);
    assert_eq!(leases.lease_for("api.github.com", NOW).map(|l| l.tier), Some(Tier::Act));
    assert_eq!(leases.lease_for("github.com", NOW + 7).map(|l| l.tier), Some(Tier::Read));
    assert!(leases.refusal("github.com", NOW + 10).is_some(), "expired at its expiry");
    assert!(leases.refusal("linear.app", NOW).is_some(), "an expired lease reaches nothing");
    assert!(leases.refusal("evil.com", NOW).is_some());
    assert!(leases.refusal("github.com.evil.com", NOW).is_some());
    assert_eq!(leases.live_sites(NOW), ["github.com"]);
}

#[test]
fn tiers_and_scopes_round_trip() {
    for tier in [Tier::Read, Tier::Act, Tier::Commit] {
        assert_eq!(Tier::parse(tier.as_str()).unwrap(), tier);
    }
    for scope in [AgentScope::Session, AgentScope::Agent, AgentScope::Workspace] {
        assert_eq!(AgentScope::parse(scope.as_str()).unwrap(), scope);
    }
    assert!(Tier::parse("admin").is_err());
    assert!(AgentScope::parse("global").is_err());
}

#[test]
fn agent_tabs_follow_the_workspace_profile_unless_switched_on() {
    assert_eq!(agent_tab_profile(false, "work"), "work");
    assert_eq!(agent_tab_profile(true, "work"), AGENTS_PROFILE);
}
