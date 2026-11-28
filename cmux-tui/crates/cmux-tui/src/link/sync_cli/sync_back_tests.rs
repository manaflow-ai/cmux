use serde_json::json;

use super::*;

#[test]
fn a_folder_turned_off_refuses_and_so_does_a_folder_inside_it() {
    let state = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    let inner = work.path().join("app");
    std::fs::create_dir_all(&inner).unwrap();
    assert_eq!(refused_in(Some(state.path()), None, work.path()), None);

    set_in(state.path(), work.path(), false).unwrap();
    let off = refused_in(Some(state.path()), None, work.path()).unwrap();
    assert_eq!(off.by, "folder");
    assert!(off.to_string().contains("sync-back is off"), "{off}");
    assert_eq!(refused_in(Some(state.path()), None, &inner).unwrap().by, "folder");

    let other = tempfile::tempdir().unwrap();
    assert_eq!(refused_in(Some(state.path()), None, other.path()), None);

    set_in(state.path(), work.path(), true).unwrap();
    assert_eq!(refused_in(Some(state.path()), None, work.path()), None);
}

#[test]
fn the_policy_turns_it_off_everywhere_and_nothing_local_turns_it_back_on() {
    let state = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    set_in(state.path(), work.path(), true).unwrap();
    for policy in
        [json!({"projection.syncBack": false}), json!({"projection": {"syncBack": false}})]
    {
        let off = refused_in(Some(state.path()), Some(&policy), work.path()).unwrap();
        assert_eq!(off.by, "policy");
        assert!(off.to_string().contains("projection.syncBack"), "{off}");
        // No state folder: the policy still holds.
        assert_eq!(refused_in(None, Some(&policy), work.path()).unwrap().by, "policy");
    }
    let open = json!({"projection": {"syncBack": true}});
    assert_eq!(refused_in(Some(state.path()), Some(&open), work.path()), None);
    assert_eq!(policy_sync_back(&json!({"egress": "none"})), None);
}

#[test]
fn a_refusal_carries_its_code_through_anyhow() {
    let error: anyhow::Error = SyncBackOff { folder: "/x".into(), by: "folder" }.into();
    assert_eq!(code_of(&error), Some(CODE));
    assert_eq!(super::super::pull::failure_code(&error), CODE);
    assert_eq!(super::super::seed_pull::failure_code(&error), CODE);
    assert_eq!(code_of(&anyhow::anyhow!("other")), None);
}

#[test]
fn turning_a_folder_off_twice_lists_it_once() {
    let state = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    set_in(state.path(), work.path(), false).unwrap();
    set_in(state.path(), work.path(), false).unwrap();
    assert_eq!(listed(state.path(), List::SyncBackOff).len(), 1);
}

#[test]
fn a_read_only_folder_mounts_without_an_upper_layer_and_has_no_way_back() {
    let state = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    let inner = work.path().join("app");
    std::fs::create_dir_all(&inner).unwrap();
    assert_eq!(read_only_in(Some(state.path()), None, work.path()), None);

    set_listed(state.path(), List::ReadOnly, work.path(), true).unwrap();
    assert_eq!(read_only_in(Some(state.path()), None, &inner), Some("folder"));
    let off = refused_in(Some(state.path()), None, &inner).unwrap();
    assert_eq!(off.by, "read_only");
    assert!(off.to_string().contains("read-only"), "{off}");

    set_listed(state.path(), List::ReadOnly, work.path(), false).unwrap();
    assert_eq!(read_only_in(Some(state.path()), None, work.path()), None);
    assert_eq!(refused_in(Some(state.path()), None, work.path()), None);

    let policy = json!({"projection": {"readOnly": true}});
    assert_eq!(read_only_in(None, Some(&policy), work.path()), Some("policy"));
}

#[test]
fn a_machine_that_mounted_a_read_only_folder_writable_is_refused() {
    use super::super::project::read_only_kept;
    let old = json!({"ok": true, "data": {"at": "/w"}});
    let kept = json!({"ok": true, "data": {"at": "/w", "read_only": true}});
    let refused = json!({"ok": false, "error_code": "projection.busy"});
    let error = read_only_kept(true, &old).unwrap_err();
    assert!(error.to_string().contains("projection.read_only_unsupported"), "{error}");
    read_only_kept(true, &kept).unwrap();
    // A refusal keeps its own error; a writable folder asks nothing.
    read_only_kept(true, &refused).unwrap();
    read_only_kept(false, &old).unwrap();
}

/// The real ways back refuse before they dial: a folder turned off answers `sync_back_off` with
/// a socket nothing listens on, where one left on fails to connect instead.
#[test]
fn sync_pull_and_project_back_refuse_a_folder_turned_off_before_they_dial() {
    const CHILD: &str = "CMUX_SYNC_BACK_TEST_CHILD";
    if let Some(want) = std::env::var_os(CHILD) {
        let folder = PathBuf::from(std::env::var_os("CMUX_SYNC_BACK_TEST_FOLDER").unwrap());
        let socket = folder.join("no-such.sock");
        let pulled = super::super::pull::pull_per_file(&socket, &folder, "/remote/x");
        let code = super::super::pull::failure_code(&pulled.err().unwrap());
        let back = super::super::project_back::bring_back(
            &socket,
            &super::super::project_back::Recorded {
                name: "x".into(),
                remote: "/remote/x".into(),
                local: folder.clone(),
            },
            false,
        );
        let back_code = match back {
            super::super::Back::Failed { code, .. } => code,
            _ => "not refused".into(),
        };
        if want == "off" {
            assert_eq!(code, CODE);
            assert_eq!(back_code, CODE);
        } else {
            assert_ne!(code, CODE);
            assert_ne!(back_code, CODE);
        }
        return;
    }
    for want in ["on", "off"] {
        let state = tempfile::tempdir().unwrap();
        let folder = tempfile::tempdir().unwrap();
        if want == "off" {
            set_in(state.path(), folder.path(), false).unwrap();
        }
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("sync_pull_and_project_back_refuse_a_folder_turned_off_before_they_dial")
            .env("CMUX_TUI_STATE_DIR", state.path())
            .env_remove(rule::POLICY_ENV)
            .env("CMUX_SYNC_BACK_TEST_FOLDER", folder.path())
            .env(CHILD, want)
            .status()
            .unwrap();
        assert!(status.success(), "sync-back {want}");
    }
}

#[test]
fn the_teams_saved_policy_turns_it_off_too() {
    let state = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    let team_path = cmux_config::location::team_policy_path(state.path());
    std::fs::create_dir_all(team_path.parent().unwrap()).unwrap();
    std::fs::write(
        &team_path,
        json!({"managed": true, "features": {"projection.syncBack": {"value": false, "mode": "enforced"}}})
            .to_string(),
    )
    .unwrap();
    let policy = read_policy(Some(state.path()));
    let off = refused_in(Some(state.path()), policy.as_ref(), work.path()).unwrap();
    assert_eq!(off.by, "policy");

    assert_eq!(team_sync_back(&json!({"features": {"projection.syncBack": true}})), Some(true));
    assert_eq!(team_sync_back(&json!({"features": {}})), None);
}

#[test]
fn the_teams_sync_back_off_keeps_the_files_read_only() {
    let state = tempfile::tempdir().unwrap();
    let work = tempfile::tempdir().unwrap();
    let team_path = cmux_config::location::team_policy_path(state.path());
    std::fs::create_dir_all(team_path.parent().unwrap()).unwrap();
    std::fs::write(&team_path, json!({"features": {"projection.syncBack": false}}).to_string()).unwrap();
    std::fs::write(
        state.path().join(rule::POLICY_FILE),
        json!({"projection": {"readOnly": true}}).to_string(),
    )
    .unwrap();
    let policy = read_policy(Some(state.path()));
    assert_eq!(read_only_in(Some(state.path()), policy.as_ref(), work.path()), Some("policy"));
    assert_eq!(refused_in(Some(state.path()), policy.as_ref(), work.path()).unwrap().by, "policy");
}
