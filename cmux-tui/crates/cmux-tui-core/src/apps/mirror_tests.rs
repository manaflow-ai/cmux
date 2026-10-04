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
    let seed = (0..APPS.len(), any::<bool>())
        .prop_map(|(i, hidden)| Op::Seed { app: APPS[i].to_string(), hidden });
    let restore = (0..APPS.len()).prop_map(|i| Op::Restore { app: APPS[i].to_string() });
    prop_oneof![4 => set, 1 => seed, 1 => restore]
}

fn app_of(op: &Op) -> &str {
    match op {
        Op::Seed { app, .. } | Op::Restore { app } => app,
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
fn tiers_decide_the_install_grants() {
    let m =
        apply(&Mirror::default(), set("1", "octo/b", |o| o.installed = Some(true))).unwrap().mirror;
    let b = &m.apps["octo/b"];
    assert!(
        !b.sandboxed
            && b.grants.contains("workspace:write")
            && b.grants.contains("net:api.github.com")
    );
    let m = apply(&m, set("2", "local/c", |o| o.installed = Some(true))).unwrap().mirror;
    let c = &m.apps["local/c"];
    assert!(c.sandboxed);
    assert_eq!(c.grants.iter().cloned().collect::<Vec<_>>(), ["workspace:read"]);
    assert_eq!(c.source, Source::Local);
}

#[test]
fn unverified_apps_never_hold_restricted_scopes() {
    // usage:read is restricted in scope-classes.json: a read scope an
    // unverified app neither gets at install nor through a later grant.
    let mut facts = facts(Tier::Unverified, Source::Local);
    facts.requested.insert("usage:read".into());
    let set_c = |key: &str, f: fn(&mut SetOp)| set(key, "local/c", f);
    let m = reduce(&Mirror::default(), &set_c("1", |o| o.installed = Some(true)), Some(&facts))
        .unwrap()
        .mirror;
    assert_eq!(m.apps["local/c"].grants.iter().cloned().collect::<Vec<_>>(), ["workspace:read"]);
    assert_eq!(
        reduce(&m, &set_c("2", |o| o.grant = Some(("usage:read".into(), true))), Some(&facts)),
        Err(Reject::ScopeRestricted("usage:read".into()))
    );
    let verified = Facts { tier: Tier::Verified, ..facts };
    let m = reduce(&Mirror::default(), &set_c("1", |o| o.installed = Some(true)), Some(&verified))
        .unwrap()
        .mirror;
    assert!(m.apps["local/c"].grants.contains("usage:read"));
}

#[test]
fn default_apps_are_seeded_once_with_required_scopes() {
    let m =
        apply(&Mirror::default(), Op::Seed { app: "cmux/a".into(), hidden: false }).unwrap().mirror;
    assert_eq!(m.apps["cmux/a"].source, Source::Default);
    assert!(m.apps["cmux/a"].installed && !m.apps["cmux/a"].hidden);
    let hidden = apply(&m, set("1", "cmux/a", |o| o.hidden = Some(true))).unwrap().mirror;
    let seeded_again = apply(&hidden, Op::Seed { app: "cmux/a".into(), hidden: false }).unwrap();
    assert!(!seeded_again.changed, "a hidden default app stays hidden");
    // A deployment default may start hidden: still installed.
    let quiet =
        apply(&Mirror::default(), Op::Seed { app: "cmux/a".into(), hidden: true }).unwrap().mirror;
    assert!(quiet.apps["cmux/a"].installed && quiet.apps["cmux/a"].hidden);
}

#[test]
fn first_party_apps_can_be_hidden_but_never_removed() {
    let m =
        apply(&Mirror::default(), Op::Seed { app: "cmux/a".into(), hidden: false }).unwrap().mirror;
    assert_eq!(
        apply(&m, set("1", "cmux/a", |o| o.installed = Some(false))),
        Err(Reject::FirstPartyHideOnly)
    );
    assert_eq!(Reject::FirstPartyHideOnly.code(), "apps.first_party_hide_only");
    let hidden = apply(&m, set("2", "cmux/a", |o| o.hidden = Some(true))).unwrap().mirror;
    assert!(hidden.apps["cmux/a"].installed && hidden.apps["cmux/a"].hidden);
    // A third-party app is still removable.
    let b = apply(&m, set("3", "octo/b", |o| o.installed = Some(true))).unwrap().mirror;
    let removed = apply(&b, set("4", "octo/b", |o| o.installed = Some(false))).unwrap().mirror;
    assert!(!removed.apps["octo/b"].installed);
}

#[test]
fn a_removed_first_party_app_is_restored_installed_and_hidden() {
    // A mirror from before the hide-only rule: a removed default app's
    // tombstone (installed false) and a removed third-party app.
    let mut m = Mirror::default();
    m.apps.insert("cmux/a".into(), absent(Source::Default, None));
    m.apps.insert("octo/b".into(), absent(Source::User, None));
    let restored = apply(&m, Op::Restore { app: "cmux/a".into() }).unwrap();
    assert!(restored.changed);
    let a = &restored.mirror.apps["cmux/a"];
    assert!(a.installed && a.hidden && a.enabled, "{a:?}");
    assert_eq!(
        a.grants.iter().cloned().collect::<Vec<_>>(),
        ["net:api.github.com", "workspace:read", "workspace:write"]
    );
    assert_eq!(restored.mirror.revision, m.revision + 1);
    // Idempotent, and a third-party app is not touched.
    assert!(!apply(&restored.mirror, Op::Restore { app: "cmux/a".into() }).unwrap().changed);
    assert!(!apply(&m, Op::Restore { app: "octo/b".into() }).unwrap().changed);
}

#[test]
fn installs_and_grants_need_a_user_but_hiding_does_not() {
    let m =
        apply(&Mirror::default(), set("1", "octo/b", |o| o.installed = Some(true))).unwrap().mirror;
    let agent = |key: &str, f: fn(&mut SetOp)| {
        set(key, "octo/b", |o| {
            o.origin = Origin::Mcp;
            f(o);
        })
    };
    assert_eq!(
        apply(&m, agent("2", |o| o.installed = Some(false))),
        Err(Reject::Origin("installed"))
    );
    assert_eq!(
        apply(&m, agent("3", |o| o.grant = Some(("agent:read".into(), true)))),
        Err(Reject::Origin("grants"))
    );
    let hidden = apply(&m, agent("4", |o| o.hidden = Some(true))).unwrap().mirror;
    assert!(hidden.apps["octo/b"].hidden);
    assert_eq!(
        apply(&Mirror::default(), set("5", "octo/b", |o| o.hidden = Some(true))),
        Err(Reject::NotInstalled)
    );
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
fn an_app_gone_from_the_catalog_can_still_be_uninstalled() {
    let mut m = Mirror::default();
    m.apps.insert("gone/d".into(), Record { installed: true, ..absent(Source::User, None) });
    let out = apply(&m, set("1", "gone/d", |o| o.installed = Some(false))).unwrap();
    assert!(!out.mirror.apps["gone/d"].installed);
    assert!(out.effects.contains(&Effect::ClearStorage("gone/d".into())));
    assert_eq!(
        apply(&out.mirror, set("2", "gone/d", |o| o.hidden = Some(true))),
        Err(Reject::UnknownApp)
    );
}

#[test]
fn elevated_scopes_are_never_granted_at_install_and_need_a_user_grant() {
    // terminal:backend is elevated in scope-classes.json. It is even listed
    // in `requested` here, which the validator refuses, to prove the reducer
    // keeps it out on its own.
    for tier in [Tier::FirstParty, Tier::Verified, Tier::Unverified] {
        let mut fx = facts(tier, Source::Local);
        fx.requested.insert("terminal:backend".into());
        let install = |key: &str| set(key, "local/c", |o| o.installed = Some(true));
        let m = reduce(&Mirror::default(), &install("1"), Some(&fx)).unwrap().mirror;
        assert!(!m.apps["local/c"].grants.contains("terminal:backend"), "{tier:?} install");
        let seeded = reduce(
            &Mirror::default(),
            &Op::Seed { app: "local/c".into(), hidden: false },
            Some(&fx),
        )
        .unwrap()
        .mirror;
        assert!(!seeded.apps["local/c"].grants.contains("terminal:backend"), "{tier:?} seed");
        // A user grant adds it; any other origin is refused.
        let grant = |key: &str, origin: Origin| {
            let mut op = set(key, "local/c", |o| o.grant = Some(("terminal:backend".into(), true)));
            if let Op::Set(set) = &mut op {
                set.origin = origin;
            }
            op
        };
        for origin in [Origin::Cli, Origin::Script, Origin::Mcp, Origin::Remote] {
            assert_eq!(
                reduce(&m, &grant("2", origin), Some(&fx)),
                Err(Reject::ScopeElevated("terminal:backend".into())),
                "{tier:?} {origin:?}"
            );
        }
        let granted = reduce(&m, &grant("3", Origin::User), Some(&fx)).unwrap().mirror;
        assert!(granted.apps["local/c"].grants.contains("terminal:backend"), "{tier:?} user");
        // A revoke follows the existing grant rule: origin user only.
        let mut revoke =
            set("4", "local/c", |o| o.grant = Some(("terminal:backend".into(), false)));
        if let Op::Set(set) = &mut revoke {
            set.origin = Origin::Cli;
        }
        assert_eq!(reduce(&granted, &revoke, Some(&fx)), Err(Reject::Origin("grants")));
        let user_revoke =
            set("5", "local/c", |o| o.grant = Some(("terminal:backend".into(), false)));
        let revoked = reduce(&granted, &user_revoke, Some(&fx)).unwrap().mirror;
        assert!(!revoked.apps["local/c"].grants.contains("terminal:backend"));
    }
}
