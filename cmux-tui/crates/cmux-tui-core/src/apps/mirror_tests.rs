use super::*;

fn facts(tier: Tier, source: Source) -> Facts {
    let set = |scopes: &[&str]| scopes.iter().map(|s| s.to_string()).collect();
    Facts {
        tier,
        source,
        // A weather widget: reads the workspace, fetches one host; one
        // restricted scope an unverified app can never hold.
        requested: set(&["workspace:read", "net:api.open-meteo.com", "fs:write"]),
        // An optional standard scope and an elevated one (its own sheet).
        optional: set(&["settings:read", "terminal:backend"]),
    }
}

fn install(facts: &Facts, grant_optional: bool) -> Record {
    let op = Op::Set(SetOp {
        key: "install".into(),
        app: "cmux/weather".into(),
        origin: Origin::User,
        installed: Some(true),
        grant_optional,
        ..SetOp::default()
    });
    let outcome = reduce(&Mirror::default(), &op, Some(facts)).expect("install");
    outcome.mirror.apps["cmux/weather"].clone()
}

fn names(grants: &BTreeSet<String>) -> Vec<&str> {
    grants.iter().map(String::as_str).collect()
}

/// The consent card lists `scopes` (and `optionalScopes` with
/// grant_optional); confirming it grants each one the tier may hold,
/// never an elevated one, and a granted `net:` scope is usable at once.
#[test]
fn a_confirmed_install_grants_every_scope_its_consent_card_listed() {
    let store = facts(Tier::Unverified, Source::Bundled);
    let record = install(&store, false);
    assert_eq!(names(&record.grants), ["net:api.open-meteo.com", "workspace:read"]);
    assert!(!record.sandboxed, "the card granted the network: the sandbox must not refuse it");
    assert_eq!(record.source, Source::User);

    let record = install(&store, true);
    assert_eq!(
        names(&record.grants),
        ["net:api.open-meteo.com", "settings:read", "workspace:read"],
        "optional scopes on the card are granted; the elevated one keeps its own sheet"
    );

    for tier in [Tier::Verified, Tier::FirstParty] {
        let record = install(&facts(tier, Source::Bundled), true);
        assert_eq!(
            names(&record.grants),
            ["fs:write", "net:api.open-meteo.com", "settings:read", "workspace:read"],
            "{tier:?}"
        );
        assert!(!record.sandboxed);
    }
}

/// An unverified app whose card lists nothing that reaches out stays
/// sandboxed (app-platform.md 10) with exactly its listed scopes.
#[test]
fn a_confirmed_install_without_network_scopes_stays_sandboxed() {
    let mut quiet = facts(Tier::Unverified, Source::Bundled);
    quiet.requested = ["workspace:read", "workspace:write"].map(String::from).into();
    let record = install(&quiet, false);
    assert_eq!(names(&record.grants), ["workspace:read", "workspace:write"]);
    assert!(record.sandboxed);
}

/// A local app is added without a consent card: tier defaults.
#[test]
fn a_local_app_keeps_the_tier_defaults() {
    let record = install(&facts(Tier::Unverified, Source::Local), true);
    assert_eq!(names(&record.grants), ["workspace:read"]);
    assert!(record.sandboxed);
    assert_eq!(record.source, Source::Local);
}
