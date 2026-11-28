use super::*;
use crate::procs::Process;
use crate::store::care_tests::scratch;
use std::sync::Arc;

fn config(home: &Path, apply: bool) -> Config {
    let uses: Arc<crate::procs::Uses> = Arc::new(|| Ok::<Vec<Process>, String>(Vec::new()));
    let open: Arc<crate::procs::Open> = Arc::new(|_: &Path| Ok(None));
    Config {
        pass: pass::Options {
            roots: Vec::new(),
            sessions: Vec::new(),
            uses,
            open,
            settings: crate::policy::Settings::default(),
            apply,
            pressure: None,
            only: Vec::new(),
            measure: true,
            guarded: Arc::new(|_: &Path| false),
        },
        home: home.to_path_buf(),
        store: Store::open(home.join("store")).unwrap(),
        apply,
        only_families: vec!["xcode-derived-data".into()],
        off: Vec::new(),
        clean_caches: true,
        clone_roots: Vec::new(),
        pressure: Some(Pressure::High),
    }
}

fn project(home: &Path, name: &str, days_old: u64) -> PathBuf {
    let path = home.join("Library/Developer/Xcode/DerivedData").join(name);
    std::fs::create_dir_all(path.join("Build")).unwrap();
    std::fs::write(path.join("Build/app.o"), vec![0u8; 8192]).unwrap();
    let when = std::time::SystemTime::now() - std::time::Duration::from_secs(days_old * 86_400);
    for p in [path.join("Build/app.o"), path.join("Build"), path.clone()] {
        std::fs::File::open(&p).unwrap().set_modified(when).unwrap();
    }
    path
}

#[test]
fn a_pass_removes_an_idle_cache_and_writes_the_ledger() {
    let home = scratch("care-ledger");
    let old = project(&home, "Old-abc", 20);
    let config = config(&home, true);
    let report = run(&config, None).unwrap();
    assert!(!old.exists(), "{:?}", report.caches.items);
    assert!(report.freed > 0);
    let rows = Ledger::in_dir(&config.store.dir).for_path(&old, 10);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].family, "xcode-derived-data");
    assert_eq!(rows[0].action, "removed");
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_dry_run_removes_nothing_and_a_cleaning_switch_off_keeps_caches() {
    let home = scratch("care-dry");
    let old = project(&home, "Old-abc", 20);
    run(&config(&home, false), None).unwrap();
    assert!(old.exists());
    let mut off = config(&home, true);
    off.clean_caches = false;
    run(&off, None).unwrap();
    assert!(old.exists());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_family_switched_off_is_left_alone() {
    let home = scratch("care-off");
    let old = project(&home, "Old-abc", 20);
    let mut config = config(&home, true);
    config.off = vec!["xcode-derived-data".into()];
    run(&config, None).unwrap();
    assert!(old.exists());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn the_never_delete_file_keeps_what_it_names() {
    let home = scratch("care-never");
    let old = project(&home, "Keep-me-abc", 20);
    let gone = project(&home, "Old-def", 20);
    std::fs::create_dir_all(crate::never_delete::user_file(&home).parent().unwrap()).unwrap();
    std::fs::write(crate::never_delete::user_file(&home), "# mine\nKeep-me-*\n").unwrap();
    let config = config(&home, true);
    let report = run(&config, None).unwrap();
    assert!(old.exists());
    assert!(!gone.exists());
    let item = report.caches.items.iter().find(|i| i.path == old).unwrap();
    assert!(item.verdict.reason.contains("never-delete"), "{}", item.verdict.reason);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_family_filtered_pass_reads_no_worktree_from_sessions() {
    let home = scratch("care-filtered");
    let repo = home.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    let git = |dir: &Path, args: &[&str]| {
        let out = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
    };
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "one"]);
    let linked = home.join("linked");
    git(&repo, &["worktree", "add", "-q", "-b", "side", &linked.to_string_lossy()]);
    let mut config = config(&home, true);
    config.pass.sessions = vec![crate::policy::Session {
        name: "s".into(),
        cwd: repo.clone(),
        open: false,
        archived_checkout: None,
        updated_ms: 0,
        ids: Vec::new(),
    }];
    let report = run(&config, None).unwrap();
    assert!(report.worktrees.items.is_empty(), "{:?}", report.worktrees.items);
    assert!(report.worktrees.expired.is_empty());
    assert!(linked.exists());
    let _ = std::fs::remove_dir_all(&home);
}

/// Every family but DerivedData off: a whole pass that reads only the scratch home.
fn whole(home: &Path) -> Config {
    let mut config = config(home, false);
    config.only_families = Vec::new();
    config.off = caches::families(&caches::Layout { home, worktree_roots: &[], clone_roots: &[] })
        .iter()
        .map(|f| f.name.to_string())
        .filter(|name| name != "xcode-derived-data")
        .collect();
    config
}

#[test]
fn a_whole_pass_is_what_status_reads_back_without_walking() {
    let home = scratch("care-status");
    project(&home, "Old-abc", 30);
    let config = whole(&home);
    assert!(status(&home, &config.store, &Default::default()).unwrap().last.is_none());
    let report = run(&config, None).unwrap();
    assert!(report.reclaimable >= 8192);
    assert_eq!(report.cost.sizes_walked, 1);

    let _ = crate::walk_memo::take_cost();
    let shown = status(&home, &config.store, &Default::default()).unwrap();
    let last = shown.last.expect("the pass was recorded");
    assert_eq!(last.reclaimable(), report.reclaimable);
    assert!(
        last.families().iter().any(|f| f.name == "xcode-derived-data" && f.reclaimable >= 8192)
    );
    assert_eq!(crate::walk_memo::take_cost(), crate::walk_memo::Cost::default());

    // The next pass measures nothing again: the memo answers.
    let again = run(&config, None).unwrap();
    assert_eq!(again.reclaimable, report.reclaimable);
    assert_eq!((again.cost.sizes_walked, again.cost.sizes_reused, again.cost.stats), (0, 1, 0));
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_filtered_pass_is_not_recorded_for_status() {
    let home = scratch("care-status-filtered");
    project(&home, "Old-abc", 30);
    let config = config(&home, false);
    run(&config, None).unwrap();
    assert!(last_pass(&config.store).is_none());
    let _ = std::fs::remove_dir_all(&home);
}
