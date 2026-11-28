use super::*;
use cmux_browser_grants::DEFAULT_LEASE_MS;

const NOW: u64 = 1_800_000_000_000;

fn registry() -> (WorkspaceRegistry, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("cmux-grants-{}", new_uuid_v4()));
    (WorkspaceRegistry::open(&root, "personal").unwrap(), root)
}

fn input(holder: &str, site: &str) -> BrowserGrantInput {
    BrowserGrantInput {
        profile: "default".into(),
        holder: holder.into(),
        site: site.into(),
        granted_via: "chip".into(),
        ..BrowserGrantInput::default()
    }
}

fn holder(session: &str) -> BrowserGrantHolder<'_> {
    BrowserGrantHolder { session, agent: Some("claude"), workspace: Some("ws-1") }
}

#[test]
fn a_grant_is_a_session_lease_for_eight_hours() {
    let (mut registry, root) = registry();
    let grant = registry.grant_browser_site(input("s1", "https://www.github.com/x"), NOW).unwrap();
    assert_eq!(
        (grant.agent_scope, grant.tier, grant.site.as_str()),
        ("session", "read", "github.com")
    );
    assert_eq!(grant.expires_at, NOW + DEFAULT_LEASE_MS);
    assert!(grant.live_at(NOW) && !grant.live_at(NOW + DEFAULT_LEASE_MS));
    let leases = registry.live_browser_leases("default", &holder("s1"), NOW).unwrap();
    assert_eq!(leases.live_sites(NOW), ["github.com"]);
    // Another session holds nothing; the lease ends at its expiry.
    assert!(registry.live_browser_leases("default", &holder("s2"), NOW).unwrap().0.is_empty());
    let later = registry.live_browser_leases("default", &holder("s1"), NOW + DEFAULT_LEASE_MS);
    assert!(later.unwrap().0.is_empty());
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn revoke_and_stop_all_end_leases() {
    let (mut registry, root) = registry();
    let one = registry.grant_browser_site(input("s1", "github.com"), NOW).unwrap();
    registry.grant_browser_site(input("s1", "linear.app"), NOW).unwrap();
    let workspace = BrowserGrantInput {
        scope: Some(AgentScope::Workspace),
        tier: Some(Tier::Act),
        expires_at: Some(NOW + DEFAULT_LEASE_MS * 30),
        ..input("ws-1", "notion.so")
    };
    registry.grant_browser_site(workspace, NOW).unwrap();
    let (revoked, changed) = registry.revoke_browser_grant(&one.id, NOW + 1).unwrap();
    assert!(changed && revoked.revoked_at == Some(NOW + 1));
    assert!(!registry.revoke_browser_grant(&one.id, NOW + 2).unwrap().1, "idempotent");
    let leases = registry.live_browser_leases("default", &holder("s1"), NOW + 1).unwrap();
    assert_eq!(leases.live_sites(NOW + 1), ["linear.app", "notion.so"]);
    let stopped = registry.revoke_browser_grants_for_profile("default", NOW + 3).unwrap();
    assert_eq!(stopped.len(), 2);
    assert!(registry.live_browser_leases("default", &holder("s1"), NOW + 3).unwrap().0.is_empty());
    assert!(registry.revoke_browser_grants_for_profile("default", NOW + 4).unwrap().is_empty());
    // The rows stay, for the list.
    let listed = registry.list_browser_grants_by_profile("Default").unwrap();
    assert_eq!(listed.len(), 3);
    assert!(listed.iter().all(|grant| grant.revoked_at.is_some()));
    let on_site = registry.list_browser_grants_by_site("https://app.linear.app/").unwrap();
    assert_eq!(on_site.len(), 1);
    assert_eq!(on_site[0].site, "linear.app");
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn commit_is_never_remembered() {
    let (mut registry, root) = registry();
    for scope in [AgentScope::Agent, AgentScope::Workspace] {
        let remembered = BrowserGrantInput {
            scope: Some(scope),
            tier: Some(Tier::Commit),
            ..input("ws-1", "github.com")
        };
        let refused = registry.grant_browser_site(remembered, NOW).unwrap_err();
        assert!(refused.to_string().contains("never remembered"), "{refused}");
    }
    let once = BrowserGrantInput { tier: Some(Tier::Commit), ..input("s1", "github.com") };
    assert_eq!(registry.grant_browser_site(once, NOW).unwrap().tier, "commit");
    let too_long = BrowserGrantInput {
        tier: Some(Tier::Commit),
        expires_at: Some(NOW + DEFAULT_LEASE_MS + 1),
        ..input("s1", "github.com")
    };
    assert!(registry.grant_browser_site(too_long, NOW).is_err());
    // The table refuses one written around the API too.
    let db = registry.connection.get();
    let raw = db.execute(
        "INSERT INTO browser_grants(id, profile_id, agent_scope, holder, site, tier, expires_at,
           granted_via, created_at) VALUES('x', 'default', 'workspace', 'w', 'a.com', 'commit', 1, 'x', 1)",
        [],
    );
    assert!(raw.is_err());
    drop(db);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn a_grant_names_a_known_profile_and_one_site() {
    let (mut registry, root) = registry();
    assert!(
        registry
            .grant_browser_site(
                BrowserGrantInput { profile: "nope".into(), ..input("s1", "github.com") },
                NOW
            )
            .is_err()
    );
    for site in ["com", "*.github.com", ""] {
        assert!(registry.grant_browser_site(input("s1", site), NOW).is_err(), "{site}");
    }
    assert!(registry.grant_browser_site(input(" ", "github.com"), NOW).is_err());
    assert!(registry.list_browser_grants_by_profile("default").unwrap().is_empty());
    let _ = std::fs::remove_dir_all(root);
}
