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

#[test]
fn the_full_public_suffix_list_keeps_sites_apart() {
    // co.ke is a public suffix the old compact list did not name.
    assert_eq!(grant_site("alice.co.ke").unwrap(), "alice.co.ke");
    assert_ne!(site_of("alice.co.ke"), site_of("bob.co.ke"));
    assert!(grant_site("co.ke").is_err());
    assert_eq!(site_of("www.bbc.co.uk"), "bbc.co.uk");
    assert_eq!(site_of("a.b.github.io"), "b.github.io");
    // A suffix the list does not know: the host is its own site.
    assert_eq!(site_of("a.corp.unknowntld-xyz"), "a.corp.unknowntld-xyz");
    assert_ne!(site_of("a.corp.unknowntld-xyz"), site_of("b.corp.unknowntld-xyz"));
    let leases =
        Leases(vec![Lease { site: "alice.co.ke".into(), tier: Tier::Act, expires_at_ms: NOW + 1 }]);
    assert!(leases.refusal("www.alice.co.ke", NOW).is_none());
    assert!(leases.refusal("bob.co.ke", NOW).is_some(), "another owner under the same suffix");
}

#[test]
fn hosts_match_in_one_spelling() {
    let site = grant_site("https://münchen.de/").unwrap();
    assert_eq!(site, "xn--mnchen-3ya.de");
    assert_eq!(normalize_host("[::1]").as_deref(), Some("::1"));
    assert_eq!(normalize_host("::1").as_deref(), Some("::1"));
    let v6 = grant_site("http://[::1]:8080/").unwrap();
    assert_eq!(v6, "::1");
    let leases = Leases(vec![
        Lease { site, tier: Tier::Read, expires_at_ms: NOW + 1 },
        Lease { site: v6, tier: Tier::Read, expires_at_ms: NOW + 1 },
        // A row stored in its Unicode spelling still matches.
        Lease { site: "bücher.de".into(), tier: Tier::Read, expires_at_ms: NOW + 1 },
    ]);
    // Navigation sees the punycode host; the brackets go either way.
    assert!(leases.refusal("www.xn--mnchen-3ya.de", NOW).is_none());
    assert!(leases.refusal("münchen.de", NOW).is_none());
    assert!(leases.refusal("[::1]", NOW).is_none());
    assert!(leases.refusal("::1", NOW).is_none());
    assert!(leases.refusal("xn--bcher-kva.de", NOW).is_none());
}

#[test]
fn a_tier_bounds_what_a_lease_allows() {
    let mut leases = Leases(vec![
        Lease { site: "github.com".into(), tier: Tier::Read, expires_at_ms: NOW + 10 },
        Lease { site: "linear.app".into(), tier: Tier::Act, expires_at_ms: NOW + 10 },
    ]);
    assert!(leases.refusal_for("github.com", Tier::Read, NOW).is_none());
    let refused = leases.refusal_for("github.com", Tier::Act, NOW).unwrap();
    assert!(refused.contains("for read only"), "{refused}");
    assert!(leases.authorize("github.com", Tier::Act, NOW).is_err(), "a read lease never acts");
    assert_eq!(leases.authorize("linear.app", Tier::Act, NOW), Ok(None));
    assert_eq!(leases.authorize("linear.app", Tier::Act, NOW), Ok(None), "act lasts");
}

#[test]
fn a_commit_lease_is_spent_by_one_action() {
    let mut leases = Leases(vec![Lease {
        site: "shop.example".into(),
        tier: Tier::Commit,
        expires_at_ms: NOW + 10,
    }]);
    // Reading does not spend it.
    assert_eq!(leases.authorize("shop.example", Tier::Read, NOW), Ok(None));
    let spent = leases.authorize("www.shop.example", Tier::Act, NOW).unwrap();
    assert_eq!(spent.map(|lease| lease.tier), Some(Tier::Commit));
    assert!(leases.authorize("shop.example", Tier::Act, NOW).is_err(), "never a second action");
    assert!(leases.refusal("shop.example", NOW).is_some());
    // An act lease beside it covers acts without spending the commit.
    let mut leases = Leases(vec![
        Lease { site: "shop.example".into(), tier: Tier::Commit, expires_at_ms: NOW + 10 },
        Lease { site: "shop.example".into(), tier: Tier::Act, expires_at_ms: NOW + 10 },
    ]);
    assert_eq!(leases.authorize("shop.example", Tier::Act, NOW), Ok(None));
    assert_eq!(leases.0.len(), 2);
}
