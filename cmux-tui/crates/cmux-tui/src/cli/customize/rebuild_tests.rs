use cmux_customize::{Customize, Roots};
use serde_json::json;

use super::*;

const APPLY_STEP: &str = "Apply the pull request or ref onto its base";
const NOW: u64 = 10 * 60 * 60_000;

fn head() -> String {
    "a".repeat(40)
}

fn app() -> String {
    "c".repeat(40)
}

/// What refresh kept after asking CI for `head()` on `app()` five minutes ago.
fn asked() -> Rebuild {
    Rebuild {
        head: head(),
        base: app(),
        asked_ms: NOW - 5 * 60_000,
        run: Some(42),
        pointer: "https://files.cmux.com/cmux-next-web/pr/7/a-c.json".to_owned(),
        failed: None,
        off_by_rebuild: false,
        tries: 1,
    }
}

/// gh is never asked: the verdict did not need the run.
fn no_gh(_: u64) -> Run {
    panic!("gh asked about a run it did not need")
}

#[test]
fn a_rebuild_is_asked_for_once_per_head_and_app_commit() {
    assert_eq!(verdict(None, &head(), &app(), NOW, no_gh), Verdict::Ask);
    let rebuild = asked();
    // Asked already and CI is on it: the current bundle stays, nothing asked again.
    match verdict(Some(&rebuild), &head(), &app(), NOW, |_| Run::Building) {
        Verdict::Wait(note) => {
            assert!(note.contains("your current one stays on"), "{note}");
            assert!(note.contains("asked 5 min ago"), "{note}");
        }
        other => panic!("{other:?}"),
    }
    // Built, its pointer not readable yet: still waiting, still on.
    assert!(matches!(
        verdict(Some(&rebuild), &head(), &app(), NOW, |_| Run::Built),
        Verdict::Wait(_)
    ));
    // The app moved on, or the entry did: a new rebuild.
    assert_eq!(verdict(Some(&rebuild), &head(), &"d".repeat(40), NOW, no_gh), Verdict::Ask);
    assert_eq!(verdict(Some(&rebuild), &"e".repeat(40), &app(), NOW, no_gh), Verdict::Ask);
}

#[test]
fn a_rebuild_ci_could_not_build_falls_back_to_the_apps_own_pages() {
    let rebuild = asked();
    match verdict(Some(&rebuild), &head(), &app(), NOW, |run| {
        assert_eq!(run, 42);
        Run::Conflict
    }) {
        Verdict::Off(note) => {
            assert!(note.contains("conflicts with what changed since"), "{note}");
            assert!(note.contains("the app's own pages are back"), "{note}");
            assert!(note.contains(short(&app())), "{note}");
            assert!(!note.contains('\n'), "one line: {note}");
        }
        other => panic!("{other:?}"),
    }
}

#[test]
fn a_rebuild_nobody_built_in_time_falls_back() {
    let rebuild = Rebuild { run: None, ..asked() };
    // No run to ask about, inside the deadline: wait.
    assert!(matches!(verdict(Some(&rebuild), &head(), &app(), NOW, no_gh), Verdict::Wait(_)));
    let late = Rebuild { asked_ms: NOW - WAIT_MS - 1, ..rebuild };
    match verdict(Some(&late), &head(), &app(), NOW, no_gh) {
        Verdict::Off(note) => assert!(note.contains("CI did not build it within 60 min"), "{note}"),
        other => panic!("{other:?}"),
    }
    // A run CI is still on past the deadline keeps the bundle on.
    let slow = Rebuild { asked_ms: NOW - WAIT_MS - 1, ..asked() };
    assert!(matches!(
        verdict(Some(&slow), &head(), &app(), NOW, |_| Run::Building),
        Verdict::Wait(_)
    ));
}

#[test]
fn a_failed_rebuild_is_not_asked_again_on_the_same_app() {
    let failed = Rebuild { failed: Some("could not be rebuilt".to_owned()), ..asked() };
    assert_eq!(
        verdict(Some(&failed), &head(), &app(), NOW, no_gh),
        Verdict::Failed("could not be rebuilt".to_owned())
    );
    // A newer app commit asks again: it may apply there.
    assert_eq!(verdict(Some(&failed), &head(), &"d".repeat(40), NOW, no_gh), Verdict::Ask);
}

fn run_state_of(run: &Value) -> Run {
    run_state(run, &[])
}

#[test]
fn what_ci_says_of_a_run() {
    let step = |name: &str, conclusion: &str| json!({"name": name, "conclusion": conclusion});
    let run = |status: &str, conclusion: &str, steps: Value| {
        json!({"status": status, "conclusion": conclusion,
               "jobs": [{"conclusion": conclusion, "steps": steps}]})
    };
    assert_eq!(run_state_of(&run("queued", "", json!([]))), Run::Building);
    assert_eq!(run_state_of(&run("in_progress", "", json!([]))), Run::Building);
    assert_eq!(run_state_of(&run("completed", "success", json!([]))), Run::Built);
    assert_eq!(
        run_state_of(&run(
            "completed",
            "failure",
            json!([step("Set up job", "success"), step(APPLY_STEP, "failure")])
        )),
        Run::Failed(format!("CI failed at \"{APPLY_STEP}\""))
    );
    assert_eq!(
        run_state_of(&run(
            "completed",
            "failure",
            json!([step("Build the web bundles", "failure")])
        )),
        Run::Failed("CI failed at \"Build the web bundles\"".to_owned())
    );
    assert_eq!(
        run_state_of(&run("completed", "cancelled", json!([]))),
        Run::Failed("its CI run was cancelled".to_owned())
    );
    assert_eq!(run_state(&json!({}), &[]), Run::Unknown);
}

#[test]
fn the_run_gh_workflow_run_names() {
    let printed = "✓ Created workflow_dispatch event for cmux-next-web-bundle-publish.yml at feat-cmux-next\n\nhttps://github.com/manaflow-ai/cmux/actions/runs/19876543210\n";
    assert_eq!(run_id(printed), Some(19_876_543_210));
    assert_eq!(run_id("✓ Created workflow_dispatch event\n"), None);
}

#[test]
fn the_waiter_runs_refresh_only_when_something_finished() {
    let open = |found: bool, run: Option<Run>| Seen { asked_ms: NOW - 60_000, found, run };
    assert_eq!(look(&[], NOW), Look::Done);
    assert_eq!(look(&[open(false, None)], NOW), Look::Sleep);
    assert_eq!(look(&[open(false, Some(Run::Building))], NOW), Look::Sleep);
    // CI built it: refresh reads its pointer through latest.json too.
    assert_eq!(look(&[open(false, Some(Run::Built))], NOW), Look::Refresh);
    assert_eq!(look(&[open(false, None), open(true, None)], NOW), Look::Refresh);
    assert_eq!(look(&[open(false, Some(Run::Failed("x".to_owned())))], NOW), Look::Refresh);
    // Past the deadline: one last refresh says so.
    let late = Seen { asked_ms: NOW - WAIT_MS - 1, found: false, run: None };
    assert_eq!(look(&[late], NOW), Look::Refresh);
}

#[test]
fn rebuilds_are_kept_by_entry_name_and_the_file_goes_when_none_is_left() {
    let dir = tempfile::tempdir().unwrap();
    let customize = Customize::open(Roots::under(dir.path()));
    let mut rebuilds = Rebuilds::load(&customize);
    assert!(rebuilds.by_name.is_empty());
    rebuilds.by_name.insert("pr-7".to_owned(), asked());
    rebuilds.save().unwrap();
    let path = customize.roots().state_dir.join("layers").join(FILE);
    assert!(path.is_file());
    assert_eq!(Rebuilds::load(&customize).by_name.get("pr-7"), Some(&asked()));
    rebuilds.by_name.clear();
    rebuilds.save().unwrap();
    assert!(!path.exists());
}

#[test]
fn only_an_entry_that_is_on_or_a_rebuild_turned_off_is_rebuilt() {
    assert!(follows(true, None));
    assert!(!follows(false, None), "the person turned it off");
    assert!(!follows(false, Some(&asked())));
    let ours = Rebuild { off_by_rebuild: true, ..asked() };
    assert!(follows(false, Some(&ours)));
}

#[test]
fn status_names_an_entry_a_failed_rebuild_turned_off_in_one_line() {
    let mut rebuilds = Rebuilds::default();
    rebuilds.by_name.insert("pr-7".to_owned(), asked());
    assert_eq!(off_lines(&rebuilds, |_| true), "", "still building: its note is on the entry");
    rebuilds.by_name.insert(
        "pr-8".to_owned(),
        Rebuild {
            failed: Some("could not be rebuilt".to_owned()),
            off_by_rebuild: true,
            ..asked()
        },
    );
    assert_eq!(off_lines(&rebuilds, |_| true), "  pr-8 is off: could not be rebuilt\n");
    // Turned back on by the person, or removed: nothing to say.
    assert_eq!(off_lines(&rebuilds, |name| name != "pr-8"), "");
}

/// A failed run as `gh run view --json status,conclusion,jobs` gives it
/// (run 45034547898, 2026-11-22: the rebuild of #50293 on d185ea0).
fn failed_at_apply() -> Value {
    json!({"status": "completed", "conclusion": "failure", "jobs": [
        {"databaseId": 137245262121u64, "name": "build the web bundles for this source key",
         "conclusion": "failure", "steps": [
            {"name": "Set up job", "conclusion": "success"},
            {"name": APPLY_STEP, "conclusion": "failure"},
            {"name": "Build the web bundles", "conclusion": "skipped"}]},
        {"databaseId": 137245978894u64, "name": "publish the web bundles to files.cmux.com",
         "conclusion": "skipped", "steps": []}]})
}

#[test]
fn only_a_change_that_does_not_apply_is_a_conflict() {
    let run = failed_at_apply();
    let conflict = [
        "#50293 (d76f7ba1c7c9) does not apply onto d185ea0477ad: it conflicts with what changed since; rebase it".to_owned(),
        "Process completed with exit code 1.".to_owned(),
    ];
    assert_eq!(run_state(&run, &conflict), Run::Conflict);
    // The same step failing on the CI installation's GitHub rate limit (what
    // the live run above did) is no conflict.
    let said = ["Process completed with exit code 1.".to_owned()];
    assert_eq!(run_state(&run, &said), Run::Failed(format!("CI failed at \"{APPLY_STEP}\"")));
    let named = ["base must be a full commit sha".to_owned()];
    assert_eq!(
        run_state(&run, &named),
        Run::Failed(format!("CI failed at \"{APPLY_STEP}\": base must be a full commit sha"))
    );
}

#[test]
fn a_rebuild_that_failed_for_no_reason_of_its_own_is_asked_again_once() {
    let flake = || Run::Failed(format!("CI failed at \"{APPLY_STEP}\""));
    assert_eq!(verdict(Some(&asked()), &head(), &app(), NOW, |_| flake()), Verdict::Ask);
    let again = Rebuild { tries: 2, ..asked() };
    match verdict(Some(&again), &head(), &app(), NOW, |_| flake()) {
        Verdict::Off(note) => assert!(note.contains("CI failed at"), "{note}"),
        other => panic!("{other:?}"),
    }
    // A conflict is not asked again: it would conflict again.
    assert!(matches!(
        verdict(Some(&asked()), &head(), &app(), NOW, |_| Run::Conflict),
        Verdict::Off(_)
    ));
}
