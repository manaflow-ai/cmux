use super::cmux_vm_at;

/// A fresh machine root with these markers (removed by the caller).
fn root(kind: Option<&str>, team: bool) -> std::path::PathBuf {
    use std::sync::atomic::{AtomicU32, Ordering};
    static N: AtomicU32 = AtomicU32::new(0);
    let n = N.fetch_add(1, Ordering::SeqCst);
    let d = std::env::temp_dir().join(format!("acpmux-vm-marker-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    if let Some(kind) = kind {
        std::fs::create_dir_all(d.join("etc/cmux")).unwrap();
        std::fs::write(d.join("etc/cmux/vm-kind"), format!("{kind}\n")).unwrap();
    }
    if team {
        std::fs::create_dir_all(d.join("srv/team")).unwrap();
    }
    d
}

fn admits(kind: Option<&str>, team: bool) -> bool {
    let d = root(kind, team);
    let admitted = cmux_vm_at(&d);
    let _ = std::fs::remove_dir_all(&d);
    admitted
}

#[test]
fn only_an_owner_vm_without_team_files_is_cmux_created() {
    assert!(admits(Some("owner"), false));
    assert!(!admits(Some("owner"), true), "team files: shared");
    assert!(!admits(Some("team"), false), "a team VM");
    assert!(!admits(None, false), "a personal or SSH-added machine");
    assert!(!admits(Some("ownerx"), false));
}

/// A team files root this user cannot see into (a root-only `/srv`) is not "absent".
#[cfg(unix)]
#[test]
fn a_team_files_root_that_cannot_be_checked_counts_as_there() {
    use std::os::unix::fs::PermissionsExt;
    let d = root(Some("owner"), true);
    std::fs::set_permissions(d.join("srv"), std::fs::Permissions::from_mode(0o000)).unwrap();
    // Root reads through a 000 folder: this check means nothing there.
    let blocked = std::fs::symlink_metadata(d.join("srv/team")).is_err();
    let admitted = cmux_vm_at(&d);
    std::fs::set_permissions(d.join("srv"), std::fs::Permissions::from_mode(0o755)).unwrap();
    let _ = std::fs::remove_dir_all(&d);
    if blocked {
        assert!(!admitted, "an unreadable /srv/team must refuse");
    }
}

/// A late Cloud route must not take the explicit route-switch path: that path can end an
/// unreported helper after the turn. The quiet path retains it, then reads the new environment
/// when the helper has ended and the chat next wakes.
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn automatic_restart_late_route_preserves_an_unreported_descendant() {
    use super::*;
    use crate::config::{Config, StoreMode};
    use std::time::Duration;

    // Own every helper the fake harness starts, including a model probe's. No other process
    // writes this test's private directory. Clean them on assertion failure as well.
    struct Helpers(tempfile::TempDir);
    impl Drop for Helpers {
        fn drop(&mut self) {
            for entry in std::fs::read_dir(self.0.path()).unwrap().flatten() {
                if !entry.file_name().to_string_lossy().starts_with("helper.") {
                    continue;
                }
                if let Ok(text) = std::fs::read_to_string(entry.path())
                    && let Ok(pid) = text.trim().parse::<i32>()
                {
                    unsafe { libc::kill(pid, libc::SIGKILL) };
                }
            }
        }
    }
    let helpers = Helpers(tempfile::tempdir().unwrap());
    let helper_file = helpers.0.path().join("helper");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake], "env": {
            "FAKE_SETSID_CHILD": helper_file,
            "LATE_ROUTE_TEST": "before"
        }}},
        "defaultHarness": "fake"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.profile_sources = crate::config::ProfileSources::none();
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub
        .new_session(NewRequest { cwd: Some(helpers.0.path().to_owned()), ..Default::default() })
        .await
        .unwrap();
    let before = hub.child_for(&session).await.unwrap();
    let pid_file = helpers.0.path().join(format!("helper.{}", before.pid.unwrap()));
    let helper: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    {
        let mut cfg = hub.config.write().await;
        let env = &mut cfg.harnesses.get_mut("fake").unwrap().env;
        env.remove("FAKE_SETSID_CHILD");
        env.insert("LATE_ROUTE_TEST".into(), "after".into());
    }
    assert!(hub.idle_eligible(&session), "the helper was not reported as background work");
    hub.restart_agent_after_turn(&session);
    assert!(session.respawn_required.load(Ordering::SeqCst));
    assert!(!session.route_switch.load(Ordering::SeqCst), "no explicit-restart bypass");
    assert!(!hub.end_quiet_stale(&session, "late-route-test", None).await);
    assert_eq!(hub.child_for(&session).await.unwrap().generation, before.generation);
    assert_eq!(unsafe { libc::kill(helper, 0) }, 0, "the unreported helper survived");

    // End only the helper this fixture started, then let the shared census cache refresh.
    assert_eq!(unsafe { libc::kill(helper, libc::SIGKILL) }, 0);
    std::fs::remove_file(&pid_file).unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        while !hub.end_quiet_stale(&session, "late-route-test", None).await {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("the route restart proceeds after background work ends");
    let after = hub.child_for(&session).await.unwrap();
    assert_ne!(after.generation, before.generation);
    assert_eq!(
        session
            .launch_env
            .lock()
            .unwrap()
            .as_ref()
            .unwrap()
            .get("LATE_ROUTE_TEST")
            .map(String::as_str),
        Some("after")
    );
    hub.shutdown_all().await;
}
