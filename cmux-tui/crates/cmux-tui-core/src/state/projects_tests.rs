//! The project list's reducer (state/projects.rs, plans/cmux-next/projects.md
//! section 5): each merge rule and each user edit, one test each.

use super::projects::*;

fn refusals() -> Refusals {
    Refusals {
        home: "/Users/me".into(),
        roots: vec![
            "/Users/me/.claude".into(),
            "/Users/me/Library/Application Support/cmux/agent-home".into(),
        ],
    }
}

fn seen(path: &str, last_used_ms: i64) -> Observation {
    Observation { path: path.into(), last_used_ms }
}

fn paths(projects: &Projects, include_hidden: bool) -> Vec<&str> {
    projects.list(include_hidden).into_iter().map(|project| project.path.as_str()).collect()
}

#[test]
fn projects_rule1_a_new_path_from_a_source_is_added_with_its_times() {
    let mut projects = Projects::default();
    let changed = projects
        .observe("claude-code", &[seen("/Users/me/src/app", 50)], false, 100, &refusals())
        .unwrap();
    assert_eq!(changed, vec!["/Users/me/src/app"]);
    let project = projects.get("/Users/me/src/app").unwrap();
    assert_eq!(project.name(), "app");
    assert_eq!(project.state, ProjectState::Present);
    assert_eq!(
        project.sources["claude-code"],
        SourceSeen { first_seen_ms: 100, last_seen_ms: 100, last_used_ms: 50 }
    );
}

#[test]
fn projects_rule2_a_known_path_updates_only_its_source_never_the_users_edits() {
    let mut projects = Projects::default();
    projects.observe("codex", &[seen("/Users/me/src/app", 10)], false, 100, &refusals()).unwrap();
    projects
        .update(
            "/Users/me/src/app",
            &OverlayEdit {
                rename: Some(Some("My App".into())),
                pinned: Some(true),
                order: Some(Some(3)),
                ..Default::default()
            },
        )
        .unwrap();
    projects.observe("codex", &[seen("/Users/me/src/app", 70)], false, 200, &refusals()).unwrap();
    projects.observe("zed", &[seen("/Users/me/src/app", 90)], false, 300, &refusals()).unwrap();
    let project = projects.get("/Users/me/src/app").unwrap();
    assert_eq!(project.name(), "My App");
    assert!(project.overlay.pinned);
    assert_eq!(project.overlay.order, Some(3));
    assert_eq!(
        project.sources["codex"],
        SourceSeen { first_seen_ms: 100, last_seen_ms: 200, last_used_ms: 70 }
    );
    assert_eq!(project.last_used_ms(), 90);
}

#[test]
fn projects_rule3_a_hidden_project_stays_hidden_on_every_resync() {
    let mut projects = Projects::default();
    projects.observe("codex", &[seen("/Users/me/src/old", 10)], true, 100, &refusals()).unwrap();
    projects
        .update("/Users/me/src/old", &OverlayEdit { hidden: Some(true), ..Default::default() })
        .unwrap();
    projects.observe("codex", &[seen("/Users/me/src/old", 99)], true, 200, &refusals()).unwrap();
    projects.observe("vscode", &[seen("/Users/me/src/old", 99)], true, 300, &refusals()).unwrap();
    assert!(paths(&projects, false).is_empty());
    assert_eq!(paths(&projects, true), vec!["/Users/me/src/old"]);
}

#[test]
fn projects_rule4_gone_from_every_source_and_from_disk_is_missing_never_deleted() {
    let mut projects = Projects::default();
    projects
        .observe(
            "codex",
            &[seen("/Users/me/src/gone", 10), seen("/Users/me/src/here", 10)],
            true,
            100,
            &refusals(),
        )
        .unwrap();
    // The source no longer lists either path.
    projects.observe("codex", &[], true, 200, &refusals()).unwrap();
    let changed = projects.reconcile(|path| path == "/Users/me/src/here");
    assert_eq!(changed, vec!["/Users/me/src/gone"]);
    assert_eq!(projects.get("/Users/me/src/gone").unwrap().state, ProjectState::Missing);
    assert_eq!(projects.get("/Users/me/src/here").unwrap().state, ProjectState::Present);
    // Back on disk (a checkout restored): present again.
    assert_eq!(projects.reconcile(|_| true), vec!["/Users/me/src/gone"]);
    // A project a source still reports is present even when its folder is gone.
    projects.observe("codex", &[seen("/Users/me/src/gone", 20)], false, 300, &refusals()).unwrap();
    assert!(projects.reconcile(|_| false).iter().all(|path| path != "/Users/me/src/gone"));
}

#[test]
fn projects_rule5_a_user_added_project_survives_every_resync_and_is_unhidden() {
    let mut projects = Projects::default();
    projects.add("/Users/me/notes", 100, &refusals()).unwrap();
    projects.observe("codex", &[], true, 200, &refusals()).unwrap();
    projects.reconcile(|_| true);
    assert!(projects.get("/Users/me/notes").unwrap().sources.contains_key(USER_SOURCE));
    projects.observe("codex", &[seen("/Users/me/src/a", 1)], false, 300, &refusals()).unwrap();
    projects
        .update("/Users/me/src/a", &OverlayEdit { hidden: Some(true), ..Default::default() })
        .unwrap();
    projects.add("/Users/me/src/a", 400, &refusals()).unwrap();
    assert!(!projects.get("/Users/me/src/a").unwrap().overlay.hidden);
    assert_eq!(
        projects
            .observe(USER_SOURCE, &[seen("/Users/me/x", 1)], false, 500, &refusals())
            .unwrap_err()
            .code(),
        "invalid_argument"
    );
}

#[test]
fn projects_rule6_disabling_a_source_drops_it_and_keeps_edited_projects() {
    let mut projects = Projects::default();
    projects
        .observe(
            "cursor",
            &[seen("/Users/me/src/a", 1), seen("/Users/me/src/b", 1)],
            false,
            100,
            &refusals(),
        )
        .unwrap();
    projects.observe("codex", &[seen("/Users/me/src/b", 1)], false, 100, &refusals()).unwrap();
    projects.observe("cursor", &[seen("/Users/me/src/c", 1)], false, 100, &refusals()).unwrap();
    projects
        .update("/Users/me/src/c", &OverlayEdit { pinned: Some(true), ..Default::default() })
        .unwrap();
    let mut changed = projects.disable_source("cursor");
    changed.sort();
    assert_eq!(changed, vec!["/Users/me/src/a", "/Users/me/src/b", "/Users/me/src/c"]);
    assert!(projects.get("/Users/me/src/a").is_none(), "nothing left: removed");
    assert_eq!(
        projects.get("/Users/me/src/b").unwrap().sources.keys().collect::<Vec<_>>(),
        vec!["codex"]
    );
    assert!(projects.get("/Users/me/src/c").is_some(), "pinned by the user: kept");
}

#[test]
fn projects_rule7_home_root_temp_and_agent_homes_are_never_projects() {
    let mut projects = Projects::default();
    let refused = [
        "/",
        "/Users",
        "/Users/me",
        "/tmp/build",
        "/private/var/folders/x/y",
        "/Users/me/.claude/projects/x",
        "/Users/me/Library/Application Support/cmux/agent-home/5f1e",
    ];
    let entries: Vec<_> = refused.iter().map(|path| seen(path, 1)).collect();
    // A source's refused paths are skipped, never an error.
    assert!(projects.observe("claude-code", &entries, false, 100, &refusals()).unwrap().is_empty());
    for path in refused {
        assert_eq!(
            projects.add(path, 100, &refusals()).unwrap_err().code(),
            "refused_path",
            "{path}"
        );
    }
    for path in ["relative/dir", "/Users/me/src/", "/Users/me/src/../x", ""] {
        assert_eq!(
            projects.add(path, 100, &refusals()).unwrap_err().code(),
            "invalid_path",
            "{path:?}"
        );
    }
    // A folder named like a refused one is not inside it.
    projects.add("/Users/me/.claudette", 100, &refusals()).unwrap();
}

#[test]
fn projects_remove_hides_what_a_source_still_reports_and_deletes_the_rest() {
    let mut projects = Projects::default();
    projects.observe("codex", &[seen("/Users/me/src/a", 1)], false, 100, &refusals()).unwrap();
    projects.add("/Users/me/src/a", 100, &refusals()).unwrap();
    projects.add("/Users/me/notes", 100, &refusals()).unwrap();
    projects.remove("/Users/me/src/a").unwrap();
    projects.remove("/Users/me/notes").unwrap();
    assert!(projects.get("/Users/me/notes").is_none());
    let kept = projects.get("/Users/me/src/a").unwrap();
    assert!(kept.overlay.hidden && !kept.sources.contains_key(USER_SOURCE));
    // The next resync does not bring it back.
    projects.observe("codex", &[seen("/Users/me/src/a", 9)], true, 200, &refusals()).unwrap();
    assert!(paths(&projects, false).is_empty());
    assert_eq!(projects.remove("/Users/me/none").unwrap_err().code(), "unknown_project");
}

#[test]
fn projects_list_puts_pinned_first_by_order_then_the_most_recently_used() {
    let mut projects = Projects::default();
    projects
        .observe(
            "codex",
            &[
                seen("/Users/me/a", 10),
                seen("/Users/me/b", 30),
                seen("/Users/me/c", 20),
                seen("/Users/me/d", 5),
            ],
            false,
            100,
            &refusals(),
        )
        .unwrap();
    projects
        .update(
            "/Users/me/d",
            &OverlayEdit { pinned: Some(true), order: Some(Some(2)), ..Default::default() },
        )
        .unwrap();
    projects
        .update(
            "/Users/me/a",
            &OverlayEdit { pinned: Some(true), order: Some(Some(1)), ..Default::default() },
        )
        .unwrap();
    assert_eq!(
        paths(&projects, false),
        vec!["/Users/me/a", "/Users/me/d", "/Users/me/b", "/Users/me/c"]
    );
}

#[test]
fn projects_observe_is_idempotent_and_reports_only_real_changes() {
    let mut projects = Projects::default();
    projects.observe("codex", &[seen("/Users/me/a", 10)], true, 100, &refusals()).unwrap();
    assert!(
        projects
            .observe("codex", &[seen("/Users/me/a", 10)], true, 100, &refusals())
            .unwrap()
            .is_empty()
    );
    // An older last-used time never moves a project back.
    projects.observe("codex", &[seen("/Users/me/a", 3)], true, 100, &refusals()).unwrap();
    assert_eq!(projects.get("/Users/me/a").unwrap().last_used_ms(), 10);
}

#[test]
fn projects_bad_edits_are_refused() {
    let mut projects = Projects::default();
    projects.add("/Users/me/a", 1, &refusals()).unwrap();
    let blank = OverlayEdit { rename: Some(Some("  ".into())), ..Default::default() };
    assert_eq!(projects.update("/Users/me/a", &blank).unwrap_err().code(), "invalid_argument");
    assert_eq!(
        projects.update("/Users/me/zzz", &OverlayEdit::default()).unwrap_err().code(),
        "unknown_project"
    );
    assert_eq!(
        projects
            .observe("bad source!", &[seen("/Users/me/a", 1)], false, 1, &refusals())
            .unwrap_err()
            .code(),
        "invalid_argument"
    );
}
