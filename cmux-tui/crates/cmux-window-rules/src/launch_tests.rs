use super::*;

fn facts(
    snapshot: Option<&str>,
    live_session: Option<&str>,
    shown: Option<&str>,
    listed: &[&str],
    live: &[&str],
) -> SnapshotFacts {
    SnapshotFacts {
        snapshot_session: snapshot.map(str::to_owned),
        live_session: live_session.map(str::to_owned),
        shown: shown.map(str::to_owned),
        listed: listed.iter().map(|id| (*id).to_owned()).collect(),
        live: live.iter().map(|id| (*id).to_owned()).collect(),
    }
}

/// cmuxterm-hq#12660: the defaults named another session's snapshot (its Home
/// workspace shown): the launch drops it and lands on Home as a bare launch does.
#[test]
fn another_sessions_snapshot_is_stale() {
    let other = facts(Some("4cd043ac"), Some("9e1f"), Some("home-a"), &["home-a"], &[]);
    assert_eq!(verdict(&other), Verdict::OtherSession);
    assert!(verdict(&other).is_stale());
}

/// Same session, but the daemon lost the workspaces the window drew (a state reset that kept the registry id).
#[test]
fn a_snapshot_whose_workspaces_the_daemon_lacks_is_stale() {
    let gone = facts(Some("s1"), Some("s1"), Some("w1"), &["w1", "w2"], &[]);
    assert_eq!(verdict(&gone), Verdict::UnknownWorkspaces);
    // The shown one alone is gone: the window drew a workspace the daemon does not have.
    let shown_gone = facts(Some("s1"), Some("s1"), Some("w1"), &["w1", "w2"], &["w2"]);
    assert_eq!(verdict(&shown_gone), Verdict::UnknownWorkspaces);
    // A window record with no shown workspace whose list the daemon lacks entirely.
    let listed_gone = facts(None, Some("s1"), None, &["w1"], &[]);
    assert_eq!(verdict(&listed_gone), Verdict::UnknownWorkspaces);
}

/// A relaunch of the same daemon reopens what was last open, even when some listed workspace ended meanwhile.
#[test]
fn the_daemons_own_snapshot_is_current() {
    let same = facts(Some("s1"), Some("s1"), Some("w1"), &["w1", "w2"], &["w1", "w2"]);
    assert_eq!(verdict(&same), Verdict::Current);
    let one_ended = facts(Some("s1"), Some("s1"), Some("w1"), &["w1", "w2"], &["w1"]);
    assert_eq!(verdict(&one_ended), Verdict::Current);
    assert!(!verdict(&one_ended).is_stale());
}

/// An older daemon's file names no session, and a window that drew nothing has nothing to miss.
#[test]
fn unnamed_sessions_and_empty_windows_compare_nothing() {
    assert_eq!(verdict(&facts(None, Some("s1"), Some("w1"), &["w1"], &["w1"])), Verdict::Current);
    assert_eq!(verdict(&facts(Some("s1"), None, None, &[], &[])), Verdict::Current);
    assert_eq!(verdict(&SnapshotFacts::default()), Verdict::Current);
}

/// Before the daemon answers the app asks with the registry this home last saw live and no workspaces: another
/// session's snapshot is never drawn, and this home's own one is.
#[test]
fn before_the_daemon_answers_only_the_sessions_decide() {
    let other = facts(Some("registry-other-home"), Some("registry-this-home"), None, &[], &[]);
    assert_eq!(verdict(&other), Verdict::OtherSession);
    let own = facts(Some("registry-this-home"), Some("registry-this-home"), None, &[], &[]);
    assert_eq!(verdict(&own), Verdict::Current);
    let unrecorded = facts(Some("registry-this-home"), None, None, &[], &[]);
    assert_eq!(verdict(&unrecorded), Verdict::Current);
}

/// A home's Application Support in a fresh temporary folder.
fn app_support(name: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos())
        .unwrap_or_default();
    let root =
        std::env::temp_dir().join(format!("launch-registry-{name}-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(root.join("cmux-next")).expect("temporary folder");
    root
}

/// The one reader of `cmux-next/launch-snapshot-registry.<session>` (the app's launch read and stage 0).
#[test]
fn current_registry_id_reads_the_id_this_home_recorded() {
    let root = app_support("reads");
    let file = root.join("cmux-next").join("launch-snapshot-registry.cmux-app");
    assert_eq!(current_registry_id(&root, "cmux-app"), None, "missing file");
    std::fs::write(&file, "4cd043ac-registry").expect("write");
    assert_eq!(current_registry_id(&root, "cmux-app").as_deref(), Some("4cd043ac-registry"));
    std::fs::write(&file, "4cd043ac-registry\n").expect("write");
    assert_eq!(current_registry_id(&root, "cmux-app").as_deref(), Some("4cd043ac-registry"));
    // Another session's name reads its own file only.
    assert_eq!(current_registry_id(&root, "cmux-app-tag"), None);
    std::fs::write(&file, "  \n").expect("write");
    assert_eq!(current_registry_id(&root, "cmux-app"), None, "empty");
    std::fs::write(&file, "x".repeat(MAX_REGISTRY_ID_BYTES + 1)).expect("write");
    assert_eq!(current_registry_id(&root, "cmux-app"), None, "longer than the bound");
    std::fs::write(&file, "x".repeat(MAX_REGISTRY_ID_BYTES)).expect("write");
    assert_eq!(
        current_registry_id(&root, "cmux-app").map(|id| id.len()),
        Some(MAX_REGISTRY_ID_BYTES)
    );
    std::fs::write(&file, [0xff, 0xfe]).expect("write");
    assert_eq!(current_registry_id(&root, "cmux-app"), None, "not UTF-8");
    assert_eq!(current_registry_id(&root, "../cmux-app"), None, "a path is not a session name");
    assert_eq!(current_registry_id(&root, ""), None);
    let _ = std::fs::remove_dir_all(root);
}

// Where a launch lands (Leo 2026-11-18: "fresh startup opening home is obv fine but if it's not first time and
// the user was on a workspace and a tab, obv just take them there"; "ofc reopening home if they were prev on home
// is fine"). Each test is named for its launch-harness arm (launch-ready front check: state, case, daemon,
// snapshot, front), so a harness line and a test map one to one.

fn on(workspace: &str, pane: &str, tab: &str) -> LastFront {
    LastFront::Workspace {
        workspace: workspace.into(),
        pane: Some(pane.into()),
        tab: Some(tab.into()),
    }
}

fn kept(last: LastFront, workspace_live: bool, tab: TabStanding) -> LandingFacts {
    LandingFacts { last, workspace_live, tab }
}

fn lands_on(workspace: &str, pane: &str, tab: &str) -> Landing {
    Landing::Workspace {
        workspace: workspace.into(),
        pane: Some(pane.into()),
        tab: Some(tab.into()),
    }
}

/// Path 1, `state=kept`: a normal relaunch reopens the workspace and tab the person was last on.
#[test]
fn state_kept_reopens_the_last_workspace_and_tab() {
    let facts = kept(on("w2", "p1", "t3"), true, TabStanding::Live);
    assert_eq!(landing(&facts), lands_on("w2", "p1", "t3"));
}

/// Path 2, `state=fresh`: a bare launch with no saved state, a true first launch, opens Home.
#[test]
fn state_fresh_lands_on_home() {
    assert_eq!(landing(&LandingFacts::default()), Landing::Home { why: HomeWhy::FirstLaunch });
    // A first launch names no workspace, so what the live tree has changes nothing.
    assert_eq!(
        landing(&kept(LastFront::Nothing, true, TabStanding::Live)),
        Landing::Home { why: HomeWhy::FirstLaunch }
    );
}

/// Path 3, `state=kept case=update`: the new copy's first launch reads the old copy's saved front window (the
/// daemon keeps it, not the copy), and lands where the old copy left the person. The copy is no input.
#[test]
fn state_kept_case_update_reopens_the_old_copys_workspace_and_tab() {
    let old_copys = kept(on("w7", "p2", "t9"), true, TabStanding::Live);
    assert_eq!(landing(&old_copys), lands_on("w7", "p2", "t9"));
}

/// Path 4, `state=kept daemon=cold`: after a reboot the daemon starts cold, keeps the workspace keys and tab ids,
/// and relaunches a tab whose process died under the same terminal (or shows its restart placeholder). "Take them
/// there" means that workspace and that tab, with its relaunched terminal: a dead process never sends the launch
/// to Home.
#[test]
fn state_kept_daemon_cold_reopens_the_workspace_and_the_tab_whose_process_ended() {
    let rebooted = kept(on("w2", "p1", "t3"), true, TabStanding::Ended);
    assert_eq!(landing(&rebooted), lands_on("w2", "p1", "t3"));
    // The tab itself went (its pane closed it meanwhile): the same workspace, on its pane's current tab. Not Home.
    let tab_gone = kept(on("w2", "p1", "t3"), true, TabStanding::Gone);
    assert_eq!(
        landing(&tab_gone),
        Landing::Workspace { workspace: "w2".into(), pane: Some("p1".into()), tab: None }
    );
}

/// Path 5, `state=kept snapshot=foreign`: the launch snapshot was another session's (`Verdict::OtherSession`); the
/// launch drops what it drew from it and this daemon's own saved front window decides, as on any relaunch.
#[test]
fn state_kept_snapshot_foreign_reopens_this_daemons_own_workspace_and_tab() {
    let own = kept(on("w2", "p1", "t3"), true, TabStanding::Live);
    assert_eq!(landing(&own), lands_on("w2", "p1", "t3"));
}

/// Path 5, `state=kept snapshot=unknown`, the known exception: the saved front window's workspace is one the daemon
/// does not have (a reset or restored state, or a workspace that ended). Nothing stands in for it: Home.
#[test]
fn state_kept_snapshot_unknown_lands_on_home() {
    let unknown = kept(on("w2", "p1", "t3"), false, TabStanding::Gone);
    assert_eq!(landing(&unknown), Landing::Home { why: HomeWhy::UnknownWorkspace });
    // A tab the daemon still lists does not bring back a workspace it lacks.
    assert_eq!(
        landing(&kept(on("w2", "p1", "t3"), false, TabStanding::Live)),
        Landing::Home { why: HomeWhy::UnknownWorkspace }
    );
}

/// Path 6, `front=home` on every `state=kept` arm (normal relaunch, `case=update`, `daemon=cold`): the person was
/// last on Home, and the saved front says so (`LastFront::Home`), so the relaunch reopens Home.
#[test]
fn state_kept_front_home_reopens_home() {
    for daemon_cold in [false, true] {
        let tab = if daemon_cold { TabStanding::Ended } else { TabStanding::Live };
        assert_eq!(
            landing(&kept(LastFront::Home, true, tab)),
            Landing::Home { why: HomeWhy::LastWasHome }
        );
    }
    // Home is never inferred: Home last, a missing workspace and a missing tab are three answers.
    let home = landing(&kept(LastFront::Home, true, TabStanding::Gone));
    let unknown = landing(&kept(on("w2", "p1", "t3"), false, TabStanding::Gone));
    let tab_gone = landing(&kept(on("w2", "p1", "t3"), true, TabStanding::Gone));
    assert_eq!(home, Landing::Home { why: HomeWhy::LastWasHome });
    assert_eq!(unknown, Landing::Home { why: HomeWhy::UnknownWorkspace });
    assert!(matches!(tab_gone, Landing::Workspace { tab: None, .. }));
}

/// A saved front window with a workspace but no focused pane (an older record) reopens the workspace.
#[test]
fn a_workspace_saved_without_its_pane_reopens_the_workspace() {
    let older = LastFront::Workspace { workspace: "w2".into(), pane: None, tab: None };
    assert_eq!(
        landing(&kept(older, true, TabStanding::Gone)),
        Landing::Workspace { workspace: "w2".into(), pane: None, tab: None }
    );
}

/// The app's JSON, both ways.
#[test]
fn landing_reads_and_answers_camel_case_json() {
    let facts: LandingFacts = serde_json::from_value(serde_json::json!({
        "last": {"kind": "workspace", "workspace": "w2", "pane": "p1", "tab": "t3"},
        "workspaceLive": true, "tab": "ended"
    }))
    .unwrap();
    assert_eq!(
        serde_json::to_value(landing(&facts)).unwrap(),
        serde_json::json!({"kind": "workspace", "workspace": "w2", "pane": "p1", "tab": "t3"})
    );
    let home: LandingFacts =
        serde_json::from_value(serde_json::json!({"last": {"kind": "home"}})).unwrap();
    assert_eq!(
        serde_json::to_value(landing(&home)).unwrap(),
        serde_json::json!({"kind": "home", "why": "lastWasHome"})
    );
    let bare: LandingFacts = serde_json::from_value(serde_json::json!({})).unwrap();
    assert_eq!(
        serde_json::to_value(landing(&bare)).unwrap(),
        serde_json::json!({"kind": "home", "why": "firstLaunch"})
    );
}

// A relaunch whose saved front workspace the daemon lacks lands on Home (`HomeWhy::UnknownWorkspace`), but Home's
// workspace can come after the restore. The landing waits for it, in the saved front window, and gives up when
// that window closed or the person moved on.

fn pending(window_open: bool, home_ready: bool, moved: bool, active: Option<&str>) -> PendingHome {
    PendingHome {
        window: "front".into(),
        active: active.map(str::to_owned),
        window_open,
        home_ready,
        moved,
        moved_since_restore: moved,
    }
}

/// Review follow-up 1: Home not listed yet when the restore ended: the landing waits, then lands once it is.
#[test]
fn state_kept_snapshot_unknown_waits_for_home_then_lands() {
    assert_eq!(pending_home(&pending(true, false, false, Some("front"))), HomeStep::Wait);
    assert_eq!(
        pending_home(&pending(true, true, false, Some("front"))),
        HomeStep::Land { window: "front".into() }
    );
}

/// The wait ends without landing when the saved front window closed or the person picked something else in it.
#[test]
fn a_pending_home_landing_stops_when_the_window_closed_or_the_person_moved() {
    assert_eq!(pending_home(&pending(false, false, false, None)), HomeStep::Stop);
    assert_eq!(pending_home(&pending(false, true, false, None)), HomeStep::Stop);
    assert_eq!(pending_home(&pending(true, false, true, Some("front"))), HomeStep::Stop);
    assert_eq!(pending_home(&pending(true, true, true, Some("front"))), HomeStep::Stop);
}

/// Review follow-up 2: Home lands in the saved front window, not whichever window is active (several saved windows).
#[test]
fn state_kept_snapshot_unknown_lands_home_in_the_saved_front_window_not_the_active_one() {
    assert_eq!(
        pending_home(&pending(true, true, false, Some("second"))),
        HomeStep::Land { window: "front".into() }
    );
    assert_eq!(
        pending_home(&pending(true, true, false, None)),
        HomeStep::Land { window: "front".into() }
    );
}

#[test]
fn pending_home_reads_and_answers_camel_case_json() {
    let facts: PendingHome = serde_json::from_value(serde_json::json!({
        "window": "w1", "active": "w2", "windowOpen": true, "homeReady": true, "moved": false
    }))
    .unwrap();
    assert_eq!(
        serde_json::to_value(pending_home(&facts)).unwrap(),
        serde_json::json!({"step": "land", "window": "w1"})
    );
    let waits: PendingHome =
        serde_json::from_value(serde_json::json!({"window": "w1", "windowOpen": true})).unwrap();
    assert_eq!(
        serde_json::to_value(pending_home(&waits)).unwrap(),
        serde_json::json!({"step": "wait"})
    );
}

// What a launch opens fresh, before the saved windows decide (`fresh_landing`): the two deciders that skipped the
// rule (the empty tree's first workspace, and the New Tab workspace when no saved window is open) and the wait for
// Home.

fn fresh(
    empty_tree: bool,
    no_saved_window_open: bool,
    classic_home: bool,
    home_ensured: bool,
) -> FreshFacts {
    FreshFacts {
        empty_tree,
        no_saved_window_open,
        classic_home,
        home_ensured,
        home_not_ensured_yet: false,
    }
}

/// Decider 1, an empty tree (a fresh install, or every workspace of the person's own ended): Home once
/// `ensure_home` named it; classic Home has no Home workspace, and an `ensure_home` that named none leaves none, so
/// both make a New Tab workspace.
#[test]
fn an_empty_tree_lands_on_home_or_a_new_tab_workspace() {
    assert_eq!(fresh_landing(&fresh(true, false, false, true)), FreshLanding::Home);
    assert_eq!(fresh_landing(&fresh(true, false, true, true)), FreshLanding::NewTab);
    assert_eq!(fresh_landing(&fresh(true, false, false, false)), FreshLanding::NewTab);
    // No saved window open changes nothing for an empty tree: Home still, not a second New Tab workspace.
    assert_eq!(fresh_landing(&fresh(true, true, false, true)), FreshLanding::Home);
}

/// Decider 2, saved windows but none of them open (the last one closed, then quit): a relaunch restores only what
/// was open at quit (#31514), so the launch window opens a New Tab workspace; with a saved window open, nothing fresh.
#[test]
fn no_saved_window_open_opens_a_new_tab_workspace() {
    for classic_home in [false, true] {
        assert_eq!(fresh_landing(&fresh(false, true, classic_home, true)), FreshLanding::NewTab);
        assert_eq!(fresh_landing(&fresh(false, false, classic_home, true)), FreshLanding::Saved);
    }
}

/// Home not ensured yet (its Home starts after the first frame, so no `ensure_home` is in flight when the launch
/// asks): before `ensure_home` answers, the tree cannot tell Home from a workspace of the person's own. A fresh
/// install would miss Home for a New Tab workspace, and a relaunch would make a new workspace over its saved front.
/// The launch waits, then lands where the rule says with Home ensured.
#[test]
fn home_not_ensured_yet_waits_for_home() {
    for (empty_tree, no_saved_window_open, classic_home) in [
        (true, false, false),
        (true, true, false),
        (true, false, true),
        (false, false, false),
        (false, true, true),
    ] {
        let facts = FreshFacts {
            empty_tree,
            no_saved_window_open,
            classic_home,
            home_ensured: false,
            home_not_ensured_yet: true,
        };
        assert_eq!(fresh_landing(&facts), FreshLanding::WaitForHome, "{facts:?}");
    }
    // A fresh install: once Home is ensured, Home.
    assert_eq!(fresh_landing(&fresh(true, false, false, true)), FreshLanding::Home);
}

/// The relaunch the race broke: the saved front window is on a live workspace, and before `ensure_home` answered the
/// tree read as empty. The launch waits, then reopens the saved front (`landing`): never Home, never a new workspace.
#[test]
fn a_relaunch_before_home_is_ensured_waits_then_reopens_the_saved_front() {
    let before =
        FreshFacts { empty_tree: true, home_not_ensured_yet: true, ..FreshFacts::default() };
    assert_eq!(fresh_landing(&before), FreshLanding::WaitForHome);
    let after = fresh(false, false, false, true);
    assert_eq!(fresh_landing(&after), FreshLanding::Saved);
    assert_eq!(
        landing(&kept(on("w2", "p1", "t3"), true, TabStanding::Live)),
        lands_on("w2", "p1", "t3")
    );
}

/// The app's JSON, both ways.
#[test]
fn fresh_landing_reads_and_answers_camel_case_json() {
    let facts: FreshFacts = serde_json::from_value(serde_json::json!({
        "emptyTree": true, "noSavedWindowOpen": false, "classicHome": false, "homeEnsured": true,
        "homeNotEnsuredYet": false
    }))
    .unwrap();
    assert_eq!(
        serde_json::to_value(fresh_landing(&facts)).unwrap(),
        serde_json::json!({"kind": "home"})
    );
    let waiting: FreshFacts =
        serde_json::from_value(serde_json::json!({"homeNotEnsuredYet": true})).unwrap();
    assert_eq!(
        serde_json::to_value(fresh_landing(&waiting)).unwrap(),
        serde_json::json!({"kind": "waitForHome"})
    );
    let bare: FreshFacts = serde_json::from_value(serde_json::json!({})).unwrap();
    assert_eq!(
        serde_json::to_value(fresh_landing(&bare)).unwrap(),
        serde_json::json!({"kind": "saved"})
    );
}

/// Review F1 of #46087: the person left the restored workspace or page and came back before Home was listed.
/// Leaving drops the pending landing for good (`movedSinceRestore`, latched by the app), so Home appearing later
/// lands nothing.
#[test]
fn a_pending_home_landing_stays_dropped_after_the_person_left_and_came_back() {
    let read = |moved: bool, moved_since_restore: bool, home_ready: bool| -> PendingHome {
        serde_json::from_value(serde_json::json!({
            "window": "front", "active": "front", "windowOpen": true, "homeReady": home_ready,
            "moved": moved, "movedSinceRestore": moved_since_restore
        }))
        .unwrap()
    };
    // Left: the landing stops.
    assert_eq!(pending_home(&read(true, true, false)), HomeStep::Stop);
    // Back at the restored place, Home not listed yet, then listed: still no landing.
    assert_eq!(pending_home(&read(false, true, false)), HomeStep::Stop);
    assert_eq!(pending_home(&read(false, true, true)), HomeStep::Stop);
    // Never left: Home lands once listed.
    assert_eq!(pending_home(&read(false, false, true)), HomeStep::Land { window: "front".into() });
}
