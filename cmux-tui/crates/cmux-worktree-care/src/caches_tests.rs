use super::*;
use crate::procs::Process;
use crate::store::care_tests::scratch;

const DAY_MS: u64 = 24 * HOUR_MS;

fn families(home: &Path) -> Vec<Family> {
    default_families(home).into_iter().filter(|f| f.source == Source::Fixed).collect()
}

fn no_uses() -> Result<Vec<Process>, String> {
    Ok(Vec::new())
}

fn not_open(_: &Path) -> Result<Option<u32>, String> {
    Ok(None)
}

fn options<'a>(
    home: &'a Path,
    pressure: Pressure,
    now_ms: u64,
    apply: bool,
    uses: &'a Uses,
    open: &'a Open,
) -> Options<'a> {
    Options {
        families: families(home),
        pressure,
        now_ms,
        apply,
        uses,
        open,
        measure: true,
        home,
        never: &crate::never_delete::NONE,
        store: None,
        off: &[],
    }
}

fn derived(home: &Path, name: &str) -> PathBuf {
    let path = home.join("Library/Developer/Xcode/DerivedData").join(name);
    std::fs::create_dir_all(path.join("Build/Products")).unwrap();
    std::fs::write(path.join("Build/Products/app.o"), vec![0u8; 4096]).unwrap();
    path
}

#[test]
fn derived_data_waits_shrink_with_pressure() {
    let family = &default_families(Path::new("/h"))[0];
    let now = 30 * DAY_MS;
    let three_days = Some(now - 3 * DAY_MS);
    assert_eq!(decide(family, three_days, Pressure::Normal, now).action, Action::Keep);
    assert_eq!(decide(family, three_days, Pressure::High, now).action, Action::Reclaim);
    assert_eq!(
        decide(family, Some(now - 8 * DAY_MS), Pressure::Normal, now).action,
        Action::Reclaim
    );
    assert_eq!(
        decide(family, Some(now - 6 * HOUR_MS), Pressure::Critical, now).action,
        Action::Keep
    );
    assert_eq!(
        decide(family, Some(now - 13 * HOUR_MS), Pressure::Critical, now).action,
        Action::Reclaim
    );
}

#[test]
fn a_package_cache_goes_only_under_pressure() {
    let npm = &default_families(Path::new("/h"))[2];
    let now = 300 * DAY_MS;
    let old = Some(now - 100 * DAY_MS);
    assert_eq!(decide(npm, old, Pressure::Normal, now).action, Action::Keep);
    assert_eq!(decide(npm, old, Pressure::High, now).action, Action::Reclaim);
    assert_eq!(decide(npm, Some(now - HOUR_MS), Pressure::Critical, now).action, Action::Keep);
}

#[test]
fn unknown_activity_and_future_times_keep() {
    let family = &default_families(Path::new("/h"))[0];
    assert_eq!(decide(family, None, Pressure::Critical, DAY_MS).action, Action::Keep);
    assert_eq!(decide(family, Some(10 * DAY_MS), Pressure::Critical, DAY_MS).action, Action::Keep);
}

#[test]
fn a_report_only_pass_removes_nothing() {
    let home = scratch("caches-report");
    let project = derived(&home, "App-abc");
    let later = crate::inventory::now_ms() + 30 * DAY_MS;
    let report = run(&options(&home, Pressure::Normal, later, false, &no_uses, &not_open));
    assert!(project.exists());
    assert_eq!(report.items.len(), 1);
    assert_eq!(report.items[0].family, "xcode-derived-data");
    assert_eq!(report.items[0].verdict.action, Action::Reclaim);
    assert!(report.reclaimable > 0);
    assert_eq!(report.freed, 0);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn apply_rechecks_the_clock_and_keeps_a_fresh_folder() {
    // The pass is told it is a month later, so the verdict is Reclaim;
    // the check right before removal reads the real clock and keeps it.
    let home = scratch("caches-recheck");
    let project = derived(&home, "App-abc");
    let later = crate::inventory::now_ms() + 30 * DAY_MS;
    let report = run(&options(&home, Pressure::Normal, later, true, &no_uses, &not_open));
    assert!(project.exists());
    assert_eq!(report.items[0].verdict.action, Action::Keep);
    assert_eq!(report.freed, 0);
    let _ = std::fs::remove_dir_all(&home);
}

fn age(path: &Path, days: u64) {
    let when = std::time::SystemTime::now() - Duration::from_millis(days * DAY_MS);
    let mut stack = vec![path.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let child = entry.path();
            if std::fs::symlink_metadata(&child).unwrap().is_dir() {
                stack.push(child.clone());
            }
            let file = std::fs::File::options().read(true).open(&child).unwrap();
            file.set_modified(when).unwrap();
        }
    }
    std::fs::File::open(path).unwrap().set_modified(when).unwrap();
}

#[test]
fn apply_removes_an_idle_project_and_keeps_a_used_one() {
    let home = scratch("caches-apply");
    let idle = derived(&home, "Old-abc");
    let used = derived(&home, "New-def");
    age(&idle, 10);
    let now = crate::inventory::now_ms();
    let report = run(&options(&home, Pressure::Normal, now, true, &no_uses, &not_open));
    assert!(!idle.exists());
    assert!(used.exists());
    assert!(report.freed > 0);
    let gone = report.items.iter().find(|item| item.path == idle).unwrap();
    assert!(gone.outcome.as_ref().unwrap().ok);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_held_folder_stays() {
    let home = scratch("caches-held");
    let idle = derived(&home, "Old-abc");
    age(&idle, 10);
    let now = crate::inventory::now_ms();
    let held = idle.clone();
    let uses = move || Ok(vec![Process { pid: 1, cwd: held.join("Build"), session_id: None }]);
    let report = run(&options(&home, Pressure::Normal, now, true, &uses, &not_open));
    assert!(idle.exists());
    assert!(report.items[0].verdict.reason.contains("in use"));
    let open = |_: &Path| Ok(Some(42));
    let report = run(&options(&home, Pressure::Normal, now, true, &no_uses, &open));
    assert!(idle.exists());
    assert!(report.items[0].verdict.reason.contains("open in pid 42"));
    let failing = |_: &Path| Err("lsof: timed out".to_string());
    run(&options(&home, Pressure::Normal, now, true, &no_uses, &failing));
    assert!(idle.exists());
    let _ = std::fs::remove_dir_all(&home);
}

#[cfg(unix)]
#[test]
fn a_link_is_never_an_entry() {
    let home = scratch("caches-link");
    let elsewhere = scratch("caches-link-target");
    std::fs::write(elsewhere.join("keep"), b"x").unwrap();
    age(&elsewhere, 30);
    let root = home.join("Library/Developer/Xcode/DerivedData");
    std::fs::create_dir_all(&root).unwrap();
    std::os::unix::fs::symlink(&elsewhere, root.join("Linked-abc")).unwrap();
    std::fs::create_dir_all(home.join(".npm")).unwrap();
    std::os::unix::fs::symlink(&elsewhere, home.join(".npm/_cacache")).unwrap();
    let report = run(&options(
        &home,
        Pressure::Critical,
        crate::inventory::now_ms(),
        true,
        &no_uses,
        &not_open,
    ));
    assert!(report.items.is_empty());
    assert!(elsewhere.join("keep").exists());
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&elsewhere);
}

#[test]
fn absent_roots_report_nothing() {
    let home = scratch("caches-absent");
    let report = run(&options(
        &home,
        Pressure::Critical,
        crate::inventory::now_ms(),
        true,
        &no_uses,
        &not_open,
    ));
    assert!(report.items.is_empty());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_command_family_is_still_its_entry_with_nothing_on_disk() {
    let home = scratch("caches-command");
    let opts = options(&home, Pressure::Critical, 1, true, &no_uses, &not_open);
    for family in default_families(&home)
        .into_iter()
        .filter(|f| matches!(f.source, Source::Docker | Source::Simulators))
    {
        assert!(still_an_entry(&opts, &family, &family.root.clone()).is_ok(), "{}", family.name);
        assert!(still_an_entry(&opts, &family, &home.join("x")).is_err());
    }
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_folder_holding_a_never_delete_child_stays() {
    let home = scratch("caches-never-child");
    let idle = derived(&home, "Old-abc");
    std::fs::create_dir_all(idle.join("Logs/keep-this")).unwrap();
    age(&idle, 10);
    let never = crate::never_delete::NeverDelete::from_globs(["keep-this".to_string()]);
    let mut opts =
        options(&home, Pressure::Normal, crate::inventory::now_ms(), true, &no_uses, &not_open);
    opts.never = &never;
    let report = run(&opts);
    assert!(idle.join("Logs/keep-this").exists());
    assert!(report.items[0].verdict.reason.contains("never-delete"), "{:?}", report.items[0]);
    let _ = std::fs::remove_dir_all(&home);
}

#[cfg(unix)]
#[test]
fn a_clone_reached_through_a_link_out_of_home_is_not_an_entry() {
    let home = scratch("caches-clone-link");
    let elsewhere = scratch("caches-clone-link-target");
    std::fs::create_dir_all(elsewhere.join("repo/.git")).unwrap();
    let root = home.join(".wt/checkouts");
    std::fs::create_dir_all(&root).unwrap();
    std::os::unix::fs::symlink(&elsewhere, root.join("linked")).unwrap();
    let mine = root.join("mine");
    std::fs::create_dir_all(mine.join(".git")).unwrap();
    assert!(really_under_home(&home, &mine));
    assert!(!really_under_home(&home, &root.join("linked/repo")));
    assert!(!really_under_home(&home, &home));
    // A clone root that is itself a link is skipped.
    let mut found = Vec::new();
    clone_entries(0, &[root.join("linked")], &mut found);
    assert!(found.is_empty());
    let family = Family {
        name: "lane-clones",
        root: root.clone(),
        per_child: true,
        idle_hours: [Some(1), Some(1), Some(1)],
        kind: Kind::Unique,
        source: Source::Clones { roots: vec![root.clone()] },
    };
    let opts = options(&home, Pressure::Critical, 1, true, &no_uses, &not_open);
    assert!(still_an_entry(&opts, &family, &root.join("linked/repo")).is_err());
    assert!(elsewhere.join("repo/.git").exists());
    let _ = std::fs::remove_dir_all(&home);
    let _ = std::fs::remove_dir_all(&elsewhere);
}
