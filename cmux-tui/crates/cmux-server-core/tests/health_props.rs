//! Property tests for the health reducer (server.md 9.3).
//!
//! Generated facts avoid the hysteresis bands (battery 20-21%; disk free
//! under 7% and 4 GiB but not under 5% and 2 GiB, or under 12% and 12 GiB
//! but not under 10% and 10 GiB; quota 78-80%), where the result
//! legitimately depends on the previous severity; health_cases.rs covers
//! the bands.

use std::collections::BTreeMap;

use cmux_server_core::health::{
    AlertKey, AlertSet, BackupFacts, DiskFacts, Facts, HostId, InhibitFacts, LockFacts, Post,
    PowerFacts, PowerSource, QuotaUsage, Severity, reduce,
};
use cmux_server_core::{InstallMode, Platform};
use proptest::prelude::*;

const GIB: u64 = 1 << 30;
const HOUR: u64 = 3_600_000;

fn power() -> impl Strategy<Value = Option<PowerFacts>> {
    prop_oneof![
        Just(None),
        Just(Some(PowerFacts { source: PowerSource::Ac, battery_percent: Some(90) })),
        prop::sample::select(vec![Some(5u8), Some(50), Some(90), None]).prop_map(|pct| Some(
            PowerFacts { source: PowerSource::Battery, battery_percent: pct }
        )),
    ]
}

fn disk() -> impl Strategy<Value = Option<DiskFacts>> {
    // (total GiB, free GiB): critical, warning and clear on a 100 GiB, a
    // 1 TiB and a 40 GiB disk, including 4.9% of 1 TiB (clear: the byte
    // threshold binds) and 15% of 40 GiB (clear: the percent threshold binds).
    let cases: Vec<(u64, u64)> = vec![
        (100, 1),
        (100, 5),
        (100, 8),
        (100, 15),
        (100, 50),
        (1024, 1),
        (1024, 5),
        (1024, 15),
        (1024, 50),
        (40, 1),
        (40, 3),
        (40, 6),
    ];
    prop_oneof![
        Just(None),
        prop::sample::select(cases).prop_map(|(total, free)| Some(DiskFacts {
            free_bytes: free * GIB,
            total_bytes: total * GIB
        })),
    ]
}

fn lock() -> impl Strategy<Value = Option<LockFacts>> {
    prop::option::of((
        any::<bool>(),
        prop::sample::select(vec![None, Some(0u64), Some(200_000), Some(10 * HOUR)]),
        any::<bool>(),
    ))
    .prop_map(|o| {
        o.map(|(held, due, gui)| LockFacts {
            display_assertion_held: held,
            idle_lock_due_at_ms: due,
            gui_workload_active: gui,
        })
    })
}

fn quota() -> impl Strategy<Value = Vec<QuotaUsage>> {
    prop::collection::btree_map(
        prop::sample::select(vec!["a", "b", "c"]),
        prop::sample::select(vec![10u64, 50, 85, 100]),
        0..3,
    )
    .prop_map(|m| {
        m.into_iter()
            .map(|(app, pct)| QuotaUsage {
                app: app.to_owned(),
                bytes: pct * GIB,
                quota_bytes: 100 * GIB,
            })
            .collect()
    })
}

fn backup() -> impl Strategy<Value = Option<BackupFacts>> {
    prop::option::of((prop::option::of(0u64..200 * HOUR), prop::option::of(0u64..200 * HOUR)))
        .prop_map(|o| {
            o.map(|(last, wal)| BackupFacts {
                cluster_created_at_ms: 0,
                last_base_backup_at_ms: last,
                wal_failing_since_ms: wal,
            })
        })
}

prop_compose! {
    fn facts()(
        power in power(),
        link_up in any::<bool>(),
        has_route in any::<bool>(),
        disk in disk(),
        lock in lock(),
        flags in prop::array::uniform6(prop::option::of(any::<bool>())),
        headless in any::<bool>(),
        inhibit in prop::option::of((any::<bool>(), any::<bool>(), any::<bool>())),
        platform in prop::sample::select(vec![Platform::Linux, Platform::MacOs, Platform::Windows]),
        mode in prop::sample::select(vec![InstallMode::User, InstallMode::System]),
        quota in quota(),
        backup in backup(),
    ) -> Facts {
        let mut f = Facts::healthy(hid(), platform, mode);
        f.power = power;
        f.link_up = link_up;
        f.has_route = has_route;
        f.disk = disk;
        f.lock = lock;
        [f.sleep_on_ac_enabled, f.autorestart, f.filevault_on, f.autologin, f.linger, f.encryption_on] = flags;
        f.headless_agent_not_logged_in = headless;
        f.inhibitors = inhibit.map(|(idle, sleep, lid)| InhibitFacts { idle, sleep, handle_lid_switch: lid });
        f.quota = quota;
        f.backup = backup;
        f
    }
}

fn steps() -> impl Strategy<Value = Vec<(Facts, u64)>> {
    prop::collection::vec(
        (facts(), prop::sample::select(vec![0u64, 1_000, 29_999, 30_000, 60_000, HOUR, 24 * HOUR])),
        1..24,
    )
}

fn hid() -> HostId {
    HostId::parse("host_p").unwrap()
}

fn fresh_backup(now_ms: u64) -> BackupFacts {
    BackupFacts {
        cluster_created_at_ms: 0,
        last_base_backup_at_ms: Some(now_ms),
        wal_failing_since_ms: None,
    }
}

/// Replaces every unknown fact with its healthy known value.
fn known(f: Facts, now_ms: u64) -> Facts {
    let h = Facts::healthy(f.host_id.clone(), f.platform, f.mode);
    Facts {
        power: f.power.or(h.power),
        disk: f.disk.or(h.disk),
        lock: f.lock.or(h.lock),
        sleep_on_ac_enabled: f.sleep_on_ac_enabled.or(h.sleep_on_ac_enabled),
        autorestart: f.autorestart.or(h.autorestart),
        filevault_on: f.filevault_on.or(h.filevault_on),
        autologin: f.autologin.or(h.autologin),
        linger: f.linger.or(h.linger),
        inhibitors: f.inhibitors.or(h.inhibitors),
        encryption_on: f.encryption_on.or(h.encryption_on),
        backup: f.backup.or(Some(fresh_backup(now_ms))),
        ..f
    }
}

fn severities(s: &AlertSet) -> BTreeMap<AlertKey, Severity> {
    s.alerts().iter().map(|(k, a)| (k.clone(), a.severity)).collect()
}

/// Applies posts to a model of the feed and checks they are well formed:
/// a Notify for an open key changes its severity; a Resolve closes an open key.
fn apply(open: &mut BTreeMap<String, Severity>, posts: &[Post]) -> Result<(), TestCaseError> {
    for post in posts {
        match post {
            Post::Notify { dedupe_key, severity, .. } => {
                let old = open.insert(dedupe_key.clone(), *severity);
                prop_assert_ne!(old, Some(*severity), "duplicate notify for {}", dedupe_key);
            }
            Post::Resolve { dedupe_key } => {
                prop_assert!(
                    open.remove(dedupe_key).is_some(),
                    "resolve without raise: {}",
                    dedupe_key
                );
            }
        }
    }
    Ok(())
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(512))]

    #[test]
    fn unchanged_facts_post_nothing(steps in steps()) {
        let mut state = AlertSet::default();
        let mut now = 0;
        for (f, dt) in steps {
            now += dt;
            let (next, _) = reduce(&state, &f, now);
            let (again, posts) = reduce(&next, &f, now);
            prop_assert!(posts.is_empty(), "{:?}", posts);
            prop_assert_eq!(&again, &next);
            if let Some(w) = next.wake_at_ms() {
                prop_assert!(w > now);
            }
            state = next;
        }
    }

    #[test]
    fn every_raise_is_resolved_exactly_once(steps in steps()) {
        let mut state = AlertSet::default();
        let mut open = BTreeMap::new();
        let mut now = 0;
        for (f, dt) in steps {
            now += dt;
            let (next, posts) = reduce(&state, &f, now);
            apply(&mut open, &posts)?;
            let expected: BTreeMap<String, Severity> =
                severities(&next).into_iter().map(|(k, s)| (k.dedupe_key(&hid()), s)).collect();
            prop_assert_eq!(&open, &expected);
            state = next;
        }
        // Every fact known and healthy, including a fresh base backup.
        let end_ms = now + 1000 * HOUR;
        let mut healthy = Facts::healthy(hid(), Platform::MacOs, InstallMode::User);
        healthy.backup = Some(fresh_backup(end_ms));
        let (end, posts) = reduce(&state, &healthy, end_ms);
        apply(&mut open, &posts)?;
        prop_assert!(open.is_empty(), "{:?}", open);
        prop_assert!(end.is_empty() && end.pending().is_empty());
        // The only deadline left is the fresh backup going stale in 48 h.
        prop_assert_eq!(end.wake_at_ms(), Some(end_ms + 48 * HOUR));
        let all_resolves = posts.iter().all(|p| matches!(p, Post::Resolve { .. }));
        prop_assert!(all_resolves, "{:?}", posts);
    }

    #[test]
    fn alert_set_equals_from_scratch_evaluation(steps in steps()) {
        let mut state = AlertSet::default();
        let mut now = 0;
        for (f, dt) in steps {
            now += dt;
            // Unknown facts keep the previous alert by design, so the
            // from-scratch property is about known facts.
            let f = known(f, now);
            let (next, _) = reduce(&state, &f, now);
            let (scratch, _) = reduce(&state.timers_only(), &f, now);
            prop_assert_eq!(severities(&next), severities(&scratch));
            prop_assert_eq!(next.pending(), scratch.pending());
            prop_assert_eq!(next.wake_at_ms(), scratch.wake_at_ms());
            state = next;
        }
    }
}
