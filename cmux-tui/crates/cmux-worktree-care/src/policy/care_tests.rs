use super::*;
use crate::Facts;

const NOW: u64 = 1_800_000_000_000;

fn worktree(facts: Facts) -> Worktree {
    Worktree {
        path: PathBuf::from("/w/a"),
        branch: Some("feat/a".into()),
        head: Some("1".repeat(40)),
        locked: false,
        prunable: false,
        facts: Ok(facts),
    }
}

fn pushed(idle_hours: u64) -> Facts {
    Facts { has_remotes: true, last_activity_ms: NOW - idle_hours * HOUR_MS, ..Facts::default() }
}

fn decide_at(worktree: &Worktree, sessions: &[Session], pressure: Pressure) -> Verdict {
    decide(worktree, Some(Path::new("/r")), sessions, &[], pressure, &Settings::default(), NOW)
}

#[test]
fn an_open_session_keeps_its_worktree_however_idle() {
    let session =
        Session { name: "lane".into(), cwd: "/w/a/src".into(), open: true, updated_ms: 0 };
    let v = decide_at(&worktree(pushed(1000)), &[session], Pressure::Critical);
    assert_eq!(v.action, Action::Keep);
    assert!(v.reason.contains("lane"));
}

#[test]
fn a_closed_session_s_last_change_counts_as_use() {
    let session = Session { name: "lane".into(), cwd: "/w/a".into(), open: false, updated_ms: NOW };
    assert_eq!(
        decide_at(&worktree(pushed(1000)), &[session], Pressure::Normal).action,
        Action::Keep
    );
}

#[test]
fn a_process_inside_keeps_it() {
    let processes = [Process { pid: 7, cwd: "/w/a/web".into() }];
    let v = decide(
        &worktree(pushed(1000)),
        None,
        &[],
        &processes,
        Pressure::Critical,
        &Settings::default(),
        NOW,
    );
    assert_eq!(v.action, Action::Keep);
}

#[test]
fn a_session_active_in_the_main_checkout_gets_its_worktrees_the_longest_waits() {
    let main = Session { name: "chief".into(), cwd: "/r/src".into(), open: true, updated_ms: NOW };
    let w = worktree(pushed(30));
    assert_eq!(decide_at(&w, &[], Pressure::Critical).action, Action::Reclaim);
    assert_eq!(decide_at(&w, std::slice::from_ref(&main), Pressure::Critical).action, Action::Keep);
    let stale = Session { updated_ms: NOW - 2 * DAY_MS, ..main };
    assert_eq!(decide_at(&w, &[stale], Pressure::Critical).action, Action::Reclaim);
}

#[test]
fn locked_and_mid_rebase_worktrees_are_kept() {
    let mut locked = worktree(pushed(1000));
    locked.locked = true;
    assert_eq!(decide_at(&locked, &[], Pressure::Critical).action, Action::Keep);
    let rebasing = worktree(Facts { operation: Some("rebase".into()), ..pushed(1000) });
    assert_eq!(decide_at(&rebasing, &[], Pressure::Critical).action, Action::Keep);
}

#[test]
fn pushed_work_goes_sooner_as_the_disk_fills() {
    let w = worktree(pushed(30));
    assert_eq!(decide_at(&w, &[], Pressure::Normal).action, Action::Keep);
    assert_eq!(decide_at(&w, &[], Pressure::High).action, Action::Reclaim);
    assert_eq!(decide_at(&worktree(pushed(80)), &[], Pressure::Normal).action, Action::Reclaim);
}

#[test]
fn unpushed_work_is_archived_never_just_removed() {
    let w = worktree(Facts { unpushed: 2, changed: 1, ..pushed(200) });
    let v = decide_at(&w, &[], Pressure::Normal);
    assert_eq!(v.action, Action::Archive, "{v:?}");
    assert!(v.reason.contains("2 unpushed"));
    let young = worktree(Facts { unpushed: 2, ..pushed(30) });
    assert_eq!(decide_at(&young, &[], Pressure::High).action, Action::Keep);
}

#[test]
fn finished_work_goes_after_the_recent_window_only() {
    let finished = Facts {
        unpushed: 3,
        finished: Some("HEAD's changes are already in origin/main".into()),
        ..pushed(30)
    };
    assert_eq!(
        decide_at(&worktree(finished.clone()), &[], Pressure::Normal).action,
        Action::Archive
    );
    let fresh = Facts { last_activity_ms: NOW - HOUR_MS / 2, ..finished };
    assert_eq!(decide_at(&worktree(fresh), &[], Pressure::Critical).action, Action::Keep);
}

#[test]
fn work_no_archive_can_keep_is_only_trimmed() {
    let w = worktree(Facts {
        unarchivable: Some("nested repository vendor/x/".into()),
        build_output: vec!["node_modules/".into()],
        ..pushed(500)
    });
    let v = decide_at(&w, &[], Pressure::Critical);
    assert_eq!(v.action, Action::Trim);
    assert!(v.reason.contains("nested repository"));
}

#[test]
fn the_disk_s_used_share_names_its_pressure() {
    let settings = Settings::default();
    assert_eq!(settings.pressure(0.5), Pressure::Normal);
    assert_eq!(settings.pressure(0.85), Pressure::High);
    assert_eq!(settings.pressure(0.94), Pressure::Critical);
}
