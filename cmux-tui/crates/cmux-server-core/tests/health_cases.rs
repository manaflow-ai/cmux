//! Health reducer cases for each check of server.md 9.3, and fix data.

use cmux_server_core::health::{
    AlertKey, AlertSet, BackupFacts, CheckId, DiskFacts, FIXES, Facts, FixError, FixValues, HostId,
    InhibitFacts, LockFacts, Post, PowerFacts, PowerSource, QuotaUsage, Severity, fixes_for,
    reduce, render_argv,
};
use cmux_server_core::{InstallMode, Platform};

const GIB: u64 = 1 << 30;

fn hid(id: &str) -> HostId {
    HostId::parse(id).unwrap()
}

fn mac() -> Facts {
    Facts::healthy(hid("host_1"), Platform::MacOs, InstallMode::User)
}

fn notify(post: &Post) -> (&str, Severity) {
    match post {
        Post::Notify { dedupe_key, severity, .. } => (dedupe_key.as_str(), *severity),
        Post::Resolve { .. } => panic!("expected notify, got {post:?}"),
    }
}

fn resolved(post: &Post) -> &str {
    match post {
        Post::Resolve { dedupe_key } => dedupe_key,
        Post::Notify { .. } => panic!("expected resolve, got {post:?}"),
    }
}

fn on_battery(pct: u8) -> Option<PowerFacts> {
    Some(PowerFacts { source: PowerSource::Battery, battery_percent: Some(pct) })
}

#[test]
fn battery_waits_60s_then_escalates_and_resolves() {
    let mut f = mac();
    f.power = on_battery(50);
    let (s1, p1) = reduce(&AlertSet::default(), &f, 1_000);
    assert!(p1.is_empty() && s1.is_empty());
    assert_eq!(s1.wake_at_ms(), Some(61_000));
    let (s2, p2) = reduce(&s1, &f, 60_999);
    assert!(p2.is_empty());
    let (s3, p3) = reduce(&s2, &f, 61_000);
    assert_eq!(p3.len(), 1);
    assert_eq!(notify(&p3[0]), ("server:host_1:power.onBattery", Severity::Warning));
    let Post::Notify { title_key, fixes, check, subject, host_id, .. } = &p3[0] else {
        unreachable!()
    };
    assert_eq!(title_key, "server.health.power.onBattery.title");
    assert_eq!((*check, subject, host_id.as_str()), (CheckId::PowerOnBattery, &None, "host_1"));
    assert!(fixes.is_empty(), "plug in: no fix");

    f.power = on_battery(19);
    let (s4, p4) = reduce(&s3, &f, 70_000);
    assert_eq!(notify(&p4[0]), ("server:host_1:power.onBattery", Severity::Critical));
    // 20 and 21 stay critical (2-point hysteresis); 22 de-escalates.
    f.power = on_battery(21);
    let (s5, p5) = reduce(&s4, &f, 71_000);
    assert!(p5.is_empty());
    f.power = on_battery(22);
    let (s6, p6) = reduce(&s5, &f, 72_000);
    assert_eq!(notify(&p6[0]).1, Severity::Warning);
    f.power = Some(PowerFacts { source: PowerSource::Ac, battery_percent: Some(22) });
    let (s7, p7) = reduce(&s6, &f, 73_000);
    assert_eq!(resolved(&p7[0]), "server:host_1:power.onBattery");
    assert!(s7.is_empty() && s7.pending().is_empty());
}

#[test]
fn short_battery_blip_posts_nothing() {
    let mut f = mac();
    f.power = on_battery(80);
    let (s1, _) = reduce(&AlertSet::default(), &f, 0);
    f.power = Some(PowerFacts { source: PowerSource::Ac, battery_percent: Some(80) });
    let (s2, p2) = reduce(&s1, &f, 30_000);
    assert!(p2.is_empty() && s2.pending().is_empty() && s2.wake_at_ms().is_none());
}

#[test]
fn offline_after_30s_needs_link_and_route_down() {
    let mut f = mac();
    f.link_up = false;
    let (s, p) = reduce(&AlertSet::default(), &f, 0);
    assert!(p.is_empty() && s.pending().is_empty(), "route still up");
    f.has_route = false;
    let (s, _) = reduce(&s, &f, 0);
    let (s, p) = reduce(&s, &f, 30_000);
    assert_eq!(notify(&p[0]), ("server:host_1:network.offline", Severity::Critical));
    f.link_up = true;
    let (_, p) = reduce(&s, &f, 31_000);
    assert_eq!(resolved(&p[0]), "server:host_1:network.offline");
}

#[test]
fn disk_thresholds_and_hysteresis() {
    // A 50 GiB disk: the percent thresholds bind (10% = 5 GiB, 5% = 2.5 GiB
    // is above the 2 GiB byte threshold, so critical binds at 2 GiB).
    let mut f = Facts::healthy(hid("host_h"), Platform::Linux, InstallMode::System);
    let total = 50 * GIB;
    let at = |free_tenths_gib: u64| {
        Some(DiskFacts { free_bytes: free_tenths_gib * GIB / 10, total_bytes: total })
    };
    f.disk = at(45); // 4.5 GiB = 9%
    let (s, p) = reduce(&AlertSet::default(), &f, 0);
    assert_eq!(notify(&p[0]), ("server:host_h:disk.low", Severity::Warning));
    let Post::Notify { fixes, .. } = &p[0] else { unreachable!() };
    assert!(fixes.is_empty(), "no storage pane on Linux");
    f.disk = at(55); // 11%: below the 12% clear line, still warning
    let (s, p) = reduce(&s, &f, 1);
    assert!(p.is_empty());
    f.disk = at(22); // 2.2 GiB = 4.4%: under 5% but not under 2 GiB, still warning
    let (s, p) = reduce(&s, &f, 2);
    assert!(p.is_empty());
    f.disk = at(15); // 1.5 GiB: critical
    let (s, p) = reduce(&s, &f, 3);
    assert_eq!(notify(&p[0]).1, Severity::Critical);
    f.disk = at(30); // 6% and 3 GiB: still critical until 7% or 4 GiB
    let (s, p) = reduce(&s, &f, 4);
    assert!(p.is_empty());
    f.disk = at(35); // 7%: back to warning
    let (s, p) = reduce(&s, &f, 5);
    assert_eq!(notify(&p[0]).1, Severity::Warning);
    f.disk = at(60); // 12%: clear
    let (s, p) = reduce(&s, &f, 6);
    assert_eq!(resolved(&p[0]), "server:host_h:disk.low");
    assert!(s.is_empty());

    // A 1 TiB disk: the byte thresholds bind. 5% free is 51 GiB: no alert
    // (the reason for "and", Lawrence decision 8).
    let big = 1024 * GIB;
    f.disk = Some(DiskFacts { free_bytes: big / 20, total_bytes: big });
    assert!(reduce(&AlertSet::default(), &f, 0).1.is_empty(), "5% of 1 TiB is plenty");
    f.disk = Some(DiskFacts { free_bytes: 9 * GIB, total_bytes: big });
    let (s, p) = reduce(&AlertSet::default(), &f, 0);
    assert_eq!(notify(&p[0]).1, Severity::Warning);
    f.disk = Some(DiskFacts { free_bytes: 11 * GIB, total_bytes: big });
    let (s, p) = reduce(&s, &f, 1);
    assert!(p.is_empty(), "11 GiB is inside the 2 GiB clear margin");
    f.disk = Some(DiskFacts { free_bytes: 12 * GIB, total_bytes: big });
    let (_, p) = reduce(&s, &f, 2);
    assert_eq!(resolved(&p[0]), "server:host_h:disk.low");
    f.disk = Some(DiskFacts { free_bytes: GIB, total_bytes: big });
    assert_eq!(notify(&reduce(&AlertSet::default(), &f, 0).1[0]).1, Severity::Critical);

    // A small disk: 1.5 GiB of 8 GiB is 19%, above both percent thresholds.
    f.disk = Some(DiskFacts { free_bytes: GIB + GIB / 2, total_bytes: 8 * GIB });
    assert!(reduce(&AlertSet::default(), &f, 0).1.is_empty(), "19% free");
    f.disk = Some(DiskFacts { free_bytes: GIB / 4, total_bytes: 8 * GIB });
    assert_eq!(notify(&reduce(&AlertSet::default(), &f, 0).1[0]).1, Severity::Critical);
    f.disk = Some(DiskFacts { free_bytes: 0, total_bytes: 0 });
    assert!(reduce(&AlertSet::default(), &f, 0).1.is_empty(), "unknown total");
}

#[test]
fn lock_pending_needs_gui_workload_and_due_lock() {
    let mut f = mac();
    // The lock is due at 400 s; the window is 300 s, so the warning starts at 100 s.
    let lock = LockFacts {
        display_assertion_held: false,
        idle_lock_due_at_ms: Some(400_000),
        gui_workload_active: true,
    };
    f.lock = Some(lock);
    let (s, p) = reduce(&AlertSet::default(), &f, 0);
    assert!(p.is_empty());
    assert_eq!(s.wake_at_ms(), Some(100_000), "one-shot deadline at due - window");
    let (s, p) = reduce(&s, &f, 100_000);
    assert_eq!(notify(&p[0]), ("server:host_1:lock.pending", Severity::Warning));
    let Post::Notify { fixes, .. } = &p[0] else { unreachable!() };
    let ids: Vec<&str> = fixes.iter().map(|f| f.id).collect();
    assert_eq!(ids, ["holdDisplayAssertion", "lockScreenSettings"]);
    // The lock facts become unknown: the alert stays, nothing is posted.
    f.lock = None;
    let (s, p) = reduce(&s, &f, 110_000);
    assert!(p.is_empty());
    assert!(s.get(&AlertKey::check(CheckId::LockPending)).is_some());
    // The display assertion is held again: resolved.
    f.lock = Some(LockFacts { display_assertion_held: true, ..lock });
    assert_eq!(resolved(&reduce(&s, &f, 120_000).1[0]), "server:host_1:lock.pending");
    for other in [
        LockFacts { gui_workload_active: false, ..lock },
        LockFacts { idle_lock_due_at_ms: None, ..lock },
    ] {
        f.lock = Some(other);
        let (s, p) = reduce(&AlertSet::default(), &f, 200_000);
        assert!(p.is_empty() && s.wake_at_ms().is_none(), "{other:?}");
    }
}

#[test]
fn unknown_facts_keep_previous_state() {
    let mut f = mac();
    f.encryption_on = Some(false);
    f.power = Some(PowerFacts { source: PowerSource::Battery, battery_percent: Some(50) });
    let (s, p) = reduce(&AlertSet::default(), &f, 0);
    assert_eq!(notify(&p[0]).0, "server:host_1:encryption.off");
    let unknown = Facts::unknown(hid("host_1"), Platform::MacOs, InstallMode::User);
    let (s2, p2) = reduce(&s, &unknown, 1_000);
    assert!(p2.is_empty(), "no resolve on unknown: {p2:?}");
    assert_eq!(s2.alerts(), s.alerts());
    assert_eq!(s2.pending(), s.pending(), "the battery timer is kept");
    assert_eq!(s2.wake_at_ms(), None, "an unknown fact never fires a timer");
    // Known again and still bad: no re-raise.
    let (s3, p3) = reduce(&s2, &f, 2_000);
    assert!(p3.is_empty());
    // The battery timer kept its start: raised at 60 s.
    let (_, p4) = reduce(&s3, &f, 60_000);
    assert_eq!(notify(&p4[0]).0, "server:host_1:power.onBattery");
}

#[test]
fn host_ids_refuse_display_names() {
    for good in ["host_1", "inst_A1b2", "host_x"] {
        assert!(HostId::parse(good).is_some(), "{good}");
    }
    for bad in ["", "host_", "Lawrence's Mac mini", "mini", "host_a b", "host_a:b", "inst_é"] {
        assert!(HostId::parse(bad).is_none(), "{bad}");
    }
    let key = AlertKey::check(CheckId::DiskLow);
    assert_eq!(key.dedupe_key(&hid("host_7")), "server:host_7:disk.low");
}

#[test]
fn flag_checks_raise_with_table_severity() {
    let mut f = mac();
    f.sleep_on_ac_enabled = Some(true);
    f.autorestart = Some(false);
    f.filevault_on = Some(true);
    f.autologin = Some(false);
    f.headless_agent_not_logged_in = true;
    f.encryption_on = Some(false);
    let (s, p) = reduce(&AlertSet::default(), &f, 0);
    let got: Vec<(&str, Severity)> = p.iter().map(notify).collect();
    assert_eq!(
        got,
        [
            ("server:host_1:sleep.enabled", Severity::Info),
            ("server:host_1:restart.noAutoRestart", Severity::Info),
            ("server:host_1:restart.fileVaultWait", Severity::Warning),
            ("server:host_1:restart.notLoggedIn", Severity::Warning),
            ("server:host_1:encryption.off", Severity::Info),
        ]
    );
    let Post::Notify { fixes, .. } = &p[0] else { unreachable!() };
    assert_eq!(fixes.len(), 1);
    assert!(fixes[0].needs_admin);
    assert_eq!(s.alerts().len(), 5);

    let mut l = Facts::healthy(hid("host_h"), Platform::Linux, InstallMode::User);
    l.linger = Some(false);
    let (_, p) = reduce(&AlertSet::default(), &l, 0);
    assert_eq!(notify(&p[0]), ("server:host_h:linger.off", Severity::Critical));
    let Post::Notify { fixes, .. } = &p[0] else { unreachable!() };
    assert_eq!(fixes[0].id, "loginctl.enableLinger");
}

#[test]
fn inhibit_limited_when_user_mode_holds_only_idle() {
    let mut f = Facts::healthy(hid("host_h"), Platform::Linux, InstallMode::User);
    let only_idle = InhibitFacts { idle: true, sleep: false, handle_lid_switch: false };
    f.inhibitors = Some(only_idle);
    let (s, p) = reduce(&AlertSet::default(), &f, 0);
    assert_eq!(notify(&p[0]), ("server:host_h:inhibit.limited", Severity::Info));
    let Post::Notify { fixes, .. } = &p[0] else { unreachable!() };
    assert_eq!(fixes.len(), 1);
    assert_eq!((fixes[0].id, fixes[0].needs_admin), ("polkit.inhibitRule", true));
    // After the polkit rule, all three kinds are held: resolved.
    f.inhibitors = Some(InhibitFacts { idle: true, sleep: true, handle_lid_switch: true });
    assert_eq!(resolved(&reduce(&s, &f, 1).1[0]), "server:host_h:inhibit.limited");
    // System mode installs the rule itself; it never raises the check.
    let mut sys = Facts::healthy(hid("host_h"), Platform::Linux, InstallMode::System);
    sys.inhibitors = Some(only_idle);
    assert!(reduce(&AlertSet::default(), &sys, 0).1.is_empty());
}

#[test]
fn quota_is_per_app_with_hysteresis() {
    let mut f = Facts::healthy(hid("host_h"), Platform::Linux, InstallMode::System);
    let usage = |app: &str, pct: u64| QuotaUsage {
        app: app.into(),
        bytes: pct * GIB,
        quota_bytes: 100 * GIB,
    };
    f.quota = vec![usage("crm", 80), usage("notes", 10)];
    let (s, p) = reduce(&AlertSet::default(), &f, 0);
    assert_eq!(p.len(), 1);
    assert_eq!(notify(&p[0]), ("server:host_h:postgres.quota:crm", Severity::Warning));
    let key = AlertKey { check: CheckId::PostgresQuota, subject: Some("crm".into()) };
    assert!(s.get(&key).is_some());
    f.quota = vec![usage("crm", 79)];
    let (s, p) = reduce(&s, &f, 1);
    assert!(p.is_empty(), "holds until under 78%");
    f.quota = vec![usage("crm", 77)];
    assert_eq!(resolved(&reduce(&s, &f, 2).1[0]), "server:host_h:postgres.quota:crm");
}

#[test]
fn backup_stale_and_wake_deadline() {
    let mut f = Facts::healthy(hid("host_h"), Platform::Linux, InstallMode::System);
    let h48 = 48 * 3600 * 1000;
    f.backup = Some(BackupFacts {
        cluster_created_at_ms: 0,
        last_base_backup_at_ms: Some(1_000),
        wal_failing_since_ms: None,
    });
    let (s, p) = reduce(&AlertSet::default(), &f, 2_000);
    assert!(p.is_empty());
    assert_eq!(s.wake_at_ms(), Some(1_000 + h48));
    let (s, p) = reduce(&s, &f, 1_000 + h48);
    assert_eq!(notify(&p[0]), ("server:host_h:backup.stale", Severity::Warning));
    let Post::Notify { fixes, .. } = &p[0] else { unreachable!() };
    assert_eq!(fixes[0].id, "backupNow");
    f.backup = Some(BackupFacts {
        cluster_created_at_ms: 0,
        last_base_backup_at_ms: Some(h48),
        wal_failing_since_ms: Some(h48 + 5),
    });
    let (s, p) = reduce(&s, &f, h48 + 10);
    assert_eq!(resolved(&p[0]), "server:host_h:backup.stale");
    assert_eq!(s.wake_at_ms(), Some(h48 + 5 + 600_000), "WAL failure deadline comes first");
    let (_, p) = reduce(&s, &f, h48 + 5 + 600_000);
    assert_eq!(notify(&p[0]).0, "server:host_h:backup.stale");
    // A cluster that never had a base backup is stale 48 h after creation.
    f.backup = Some(BackupFacts {
        cluster_created_at_ms: 0,
        last_base_backup_at_ms: None,
        wal_failing_since_ms: None,
    });
    assert_eq!(reduce(&AlertSet::default(), &f, h48).1.len(), 1);
}

#[test]
fn disabled_check_resolves_and_stays_quiet() {
    let mut f = mac();
    f.encryption_on = Some(false);
    let (s, _) = reduce(&AlertSet::default(), &f, 0);
    f.settings.disabled.insert(CheckId::EncryptionOff);
    let (s, p) = reduce(&s, &f, 1);
    assert_eq!(resolved(&p[0]), "server:host_1:encryption.off");
    assert!(reduce(&s, &f, 2).1.is_empty());
}

#[test]
fn check_ids_round_trip() {
    for c in CheckId::ALL {
        assert_eq!(CheckId::parse(c.as_str()), Some(c));
    }
    assert_eq!(CheckId::parse("power.onbattery"), None);
}

#[test]
fn fix_descriptors_are_well_formed() {
    for fix in FIXES {
        let kinds = [fix.argv.is_some(), fix.opens_settings_url.is_some(), fix.internal.is_some()];
        assert_eq!(kinds.iter().filter(|k| **k).count(), 1, "{}", fix.id);
        assert!(fix.title_key.starts_with("server.health.fix."), "{}", fix.id);
        if let Some(argv) = fix.argv {
            assert!(fix.needs_admin, "{}", fix.id);
            assert!(argv.iter().all(|a| !a.contains(['{', '}']) || *a == "{user}"), "{}", fix.id);
        }
    }
    let linger = fixes_for(CheckId::LingerOff, Platform::Linux, InstallMode::User).next().unwrap();
    assert_eq!(
        render_argv(linger, &FixValues { user: Some("ana".into()) }).unwrap(),
        ["/usr/bin/loginctl", "enable-linger", "ana"]
    );
    assert_eq!(render_argv(linger, &FixValues::default()), Err(FixError::MissingValue("user")));
    assert_eq!(
        render_argv(linger, &FixValues { user: Some("ana; reboot".into()) }),
        Err(FixError::InvalidValue("user"))
    );
    assert!(fixes_for(CheckId::LingerOff, Platform::Linux, InstallMode::System).next().is_none());
    let url = fixes_for(CheckId::DiskLow, Platform::Windows, InstallMode::User).next().unwrap();
    assert_eq!(render_argv(url, &FixValues::default()), Err(FixError::NotArgv));
    assert_eq!(
        render_argv(
            fixes_for(CheckId::SleepEnabled, Platform::MacOs, InstallMode::User).next().unwrap(),
            &FixValues::default()
        )
        .unwrap(),
        ["/usr/bin/pmset", "-c", "sleep", "0", "disksleep", "0"]
    );
}

#[test]
fn windows_fix_uses_the_system_powercfg() {
    let fix =
        fixes_for(CheckId::SleepEnabled, Platform::Windows, InstallMode::System).next().unwrap();
    assert_eq!(
        render_argv(fix, &FixValues::default()).unwrap()[0],
        r"C:\Windows\System32\powercfg.exe"
    );
}

#[test]
fn disk_warning_line_is_the_smaller_threshold() {
    let s = cmux_server_core::health::HealthSettings::default();
    assert_eq!(s.disk_warning_line(1000 * GIB), 10 * GIB, "bytes bind on a large disk");
    assert_eq!(s.disk_warning_line(50 * GIB), 5 * GIB, "percent binds on a small disk");
    assert_eq!(s.disk_warning_line(0), 0);
}
