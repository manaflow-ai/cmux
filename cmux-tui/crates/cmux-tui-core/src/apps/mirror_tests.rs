//! Property and example tests for the install mirror reducer.

use std::collections::BTreeSet;

use proptest::prelude::*;

use super::mirror::*;

fn facts(tier: Tier, source: Source) -> Facts {
    Facts {
        tier,
        source,
        requested: ["workspace:read", "workspace:write", "net:api.github.com"]
            .iter()
            .map(|s| s.to_string())
            .collect(),
        optional: ["agent:read"].iter().map(|s| s.to_string()).collect(),
    }
}

const APPS: [&str; 4] = ["cmux/a", "octo/b", "local/c", "gone/d"];

fn facts_for(app: &str) -> Option<Facts> {
    match app {
        "cmux/a" => Some(facts(Tier::FirstParty, Source::Default)),
        "octo/b" => Some(facts(Tier::Verified, Source::Bundled)),
        "local/c" => Some(facts(Tier::Unverified, Source::Local)),
        _ => None,
    }
}

fn origin() -> impl Strategy<Value = Origin> {
    prop_oneof![Just(Origin::User), Just(Origin::Cli), Just(Origin::Script), Just(Origin::Mcp)]
}

fn op() -> impl Strategy<Value = Op> {
    let set = (
        0..24u8,
        0..APPS.len(),
        origin(),
        proptest::option::of(any::<bool>()),
        proptest::option::of(any::<bool>()),
        proptest::option::of(any::<bool>()),
        proptest::option::of(any::<bool>()),
        proptest::option::of((
            prop_oneof![
                Just("workspace:read"),
                Just("workspace:write"),
                Just("agent:read"),
                Just("terminal:execute")
            ],
            any::<bool>(),
        )),
    )
        .prop_map(|(key, app, origin, installed, enabled, hidden, sandboxed, grant)| {
            Op::Set(SetOp {
                key: format!("k{key}"),
                app: APPS[app].to_string(),
                origin,
                installed,
                enabled,
                hidden,
                hidden_access: None,
                sandboxed,
                grant: grant.map(|(s, g)| (s.to_string(), g)),
            })
        });
    prop_oneof![4 => set, 1 => (0..APPS.len()).prop_map(|i| Op::Seed { app: APPS[i].to_string() })]
}

fn app_of(op: &Op) -> &str {
    match op {
        Op::Seed { app } => app,
        Op::Set(set) => &set.app,
    }
}

fn check_invariants(mirror: &Mirror) -> Result<(), TestCaseError> {
    for (app, record) in &mirror.apps {
        prop_assert!(!record.hidden || record.installed, "{app}: hidden implies installed");
        if !record.installed {
            prop_assert!(
                record.grants.is_empty() && !record.enabled && !record.hidden,
                "{app}: uninstalled record keeps state: {record:?}"
            );
        }
        if let Some(f) = facts_for(app) {
            let allowed: BTreeSet<String> = f.requested.union(&f.optional).cloned().collect();
            prop_assert!(record.grants.is_subset(&allowed), "{app}: grants outside the manifest");
        }
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn random_op_sequences_keep_the_invariants(ops in proptest::collection::vec(op(), 1..60)) {
        let mut mirror = Mirror::default();
        for op in &ops {
            let facts = facts_for(app_of(op));
            let Ok(outcome) = reduce(&mirror, op, facts.as_ref()) else { continue };
            // Revision: +1 on change, else unchanged.
            prop_assert_eq!(outcome.mirror.revision, mirror.revision + u64::from(outcome.changed));
            if let Op::Set(set) = op {
                let was = mirror.apps.get(&set.app).is_some_and(|r| r.installed);
                let now = outcome.mirror.apps.get(&set.app).is_some_and(|r| r.installed);
                if was && !now {
                    // Uninstall clears storage and stops the host in the same commit.
                    prop_assert!(outcome.effects.contains(&Effect::ClearStorage(set.app.clone())));
                    prop_assert!(outcome.effects.contains(&Effect::StopHost(set.app.clone())));
                    prop_assert_eq!(set.origin, Origin::User);
                }
                if !was && now {
                    prop_assert_eq!(set.origin, Origin::User, "installs need a user action");
                }
            }
            check_invariants(&outcome.mirror)?;
            // Idempotent replay: the same op again changes nothing.
            let again = reduce(&outcome.mirror, op, facts.as_ref()).expect("replay is accepted");
            prop_assert_eq!(&again.mirror.apps, &outcome.mirror.apps);
            prop_assert_eq!(again.mirror.revision, outcome.mirror.revision);
            prop_assert!(again.effects.is_empty());
            mirror = outcome.mirror;
        }
    }
}

fn set(key: &str, app: &str, f: impl FnOnce(&mut SetOp)) -> Op {
    let mut op =
        SetOp { key: key.into(), app: app.into(), origin: Origin::User, ..SetOp::default() };
    f(&mut op);
    Op::Set(op)
}

fn apply(mirror: &Mirror, op: Op) -> Result<Outcome, Reject> {
    let facts = facts_for(app_of(&op));
    reduce(mirror, &op, facts.as_ref())
}

#[test]
fn grants_outside_the_manifest_are_refused_and_keys_cannot_be_reused() {
    let m =
        apply(&Mirror::default(), set("1", "octo/b", |o| o.installed = Some(true))).unwrap().mirror;
    assert_eq!(
        apply(&m, set("2", "octo/b", |o| o.grant = Some(("terminal:execute".into(), true)))),
        Err(Reject::ScopeNotRequested("terminal:execute".into()))
    );
    assert_eq!(apply(&m, set("1", "octo/b", |o| o.hidden = Some(true))), Err(Reject::KeyConflict));
}

#[test]
fn sidebar_layout_read_comes_with_the_app_and_write_needs_a_user_grant() {
    // The sidebar layout is the user's own arrangement
    // (plans/cmux-next/sidebar-sections.md 5): every tier reads it with the
    // app, and no tier changes it without the user's explicit grant.
    for tier in [Tier::FirstParty, Tier::Verified, Tier::Unverified] {
        let mut fx = facts(tier, Source::Local);
        fx.requested.insert("sidebar_layout:read".into());
        fx.requested.insert("sidebar_layout:write".into());
        let install = set("1", "local/c", |o| o.installed = Some(true));
        let m = reduce(&Mirror::default(), &install, Some(&fx)).unwrap().mirror;
        let grants = &m.apps["local/c"].grants;
        assert!(grants.contains("sidebar_layout:read"), "{tier:?} read");
        assert!(!grants.contains("sidebar_layout:write"), "{tier:?} write at install");
        let grant = |key: &str, origin: Origin| {
            let mut op =
                set(key, "local/c", |o| o.grant = Some(("sidebar_layout:write".into(), true)));
            if let Op::Set(set) = &mut op {
                set.origin = origin;
            }
            op
        };
        assert_eq!(
            reduce(&m, &grant("2", Origin::Mcp), Some(&fx)),
            Err(Reject::ScopeElevated("sidebar_layout:write".into())),
            "{tier:?} mcp"
        );
        let granted = reduce(&m, &grant("3", Origin::User), Some(&fx)).unwrap().mirror;
        assert!(granted.apps["local/c"].grants.contains("sidebar_layout:write"), "{tier:?} user");
    }
}

/// A scope the class table does not know (a newer manifest, or a table that
/// failed to load) is treated as elevated: never granted at install or seed,
/// and never granted by a non-user origin (fail closed, crash program H5
/// review). Before, `is_elevated` returned false for an unknown scope, so a
/// default app was seeded with it without consent.
#[test]
fn unknown_scopes_are_treated_as_elevated() {
    assert!(is_elevated("nonsense"));
    let mut seeded = facts(Tier::FirstParty, Source::Default);
    seeded.requested.insert("nonsense".into());
    let m = reduce(&Mirror::default(), &Op::Seed { app: "cmux/a".into() }, Some(&seeded))
        .unwrap()
        .mirror;
    assert!(!m.apps["cmux/a"].grants.contains("nonsense"));
    assert!(m.apps["cmux/a"].grants.contains("workspace:write"));
    let (grants, _) = seeded.install_defaults();
    assert!(!grants.contains("nonsense"));
}
