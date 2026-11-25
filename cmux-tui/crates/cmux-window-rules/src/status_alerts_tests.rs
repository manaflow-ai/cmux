//! Parity with the Swift tests these rules came from
//! (`ProgramAlertTitleTests`, `StatusRunNotificationTests`) and with the
//! daemon's `raise_alert` wording.

use super::*;

fn record(
    state: State,
    kind: Option<Kind>,
    title: Option<&str>,
    msg: Option<&str>,
    seq: u64,
) -> Record {
    Record {
        state,
        kind,
        app: None,
        title: title.map(Into::into),
        msg: msg.map(Into::into),
        updated_seq: seq,
    }
}

const VISIBLE: Visibility =
    Visibility { tab_selected: true, pane_on_screen: true, window_shown: true, app_active: true };

#[test]
fn the_wording_is_the_daemons() {
    let verbs: Vec<&str> = Reason::ALL.iter().map(|reason| reason.verb()).collect();
    assert_eq!(
        verbs,
        ["needs approval", "asks a question", "needs sign-in", "needs input", "failed", "is done"]
    );
    let levels: Vec<Level> = Reason::ALL.iter().map(|reason| reason.level()).collect();
    assert_eq!(
        levels,
        [Level::Warning, Level::Warning, Level::Warning, Level::Warning, Level::Error, Level::Info]
    );
}

#[test]
fn each_state_has_its_reason_badge_and_kind() {
    assert_eq!(Reason::of(State::Blocked, Some(Kind::Permission)), Some(Reason::Permission));
    assert_eq!(Reason::of(State::Blocked, Some(Kind::Question)), Some(Reason::Question));
    assert_eq!(Reason::of(State::Blocked, Some(Kind::Auth)), Some(Reason::Auth));
    assert_eq!(Reason::of(State::Blocked, None), Some(Reason::Input));
    assert_eq!(Reason::of(State::Error, None), Some(Reason::Failed));
    assert_eq!(Reason::of(State::Done, None), Some(Reason::Done));
    assert_eq!(Reason::of(State::Working, None), None);
    assert_eq!(Reason::of(State::Idle, None), None);
    assert_eq!(Reason::Input.indicator(), Indicator::Waiting);
    assert_eq!(Reason::Failed.indicator(), Indicator::Error);
    assert_eq!(Reason::Done.indicator(), Indicator::Success);
    assert_eq!(Reason::Auth.kind(), Some(Kind::Auth));
    assert_eq!(Reason::Input.kind(), None);
}

#[test]
fn a_blocked_programs_alert_finds_its_record() {
    let records = [record(
        State::Blocked,
        Some(Kind::Permission),
        Some("terraform apply"),
        Some("Apply 3 changes?"),
        4,
    )];
    let found =
        alert("terraform apply needs approval", "Apply 3 changes?", Level::Warning, &records);
    assert_eq!(
        found,
        Some(Alert {
            index: 0,
            reason: Reason::Permission,
            indicator: Indicator::Waiting,
            kind: Some(Kind::Permission)
        })
    );
    assert_eq!(
        alert("terraform apply needs approval", "Apply 3 changes?", Level::Info, &records),
        None,
        "the level must match"
    );
    assert_eq!(
        alert("terraform apply needs approval", "other", Level::Warning, &records),
        None,
        "the body must match"
    );
}

#[test]
fn a_failure_without_a_name_is_a_program() {
    let records = [record(State::Error, None, None, None, 1)];
    assert_eq!(
        alert("A program failed", "", Level::Error, &records).map(|found| found.reason),
        Some(Reason::Failed)
    );
    let mut named = record(State::Error, None, None, None, 1);
    named.app = Some("cargo".into());
    assert!(
        alert("cargo failed", "", Level::Error, &[named]).is_some(),
        "the app names it without a title"
    );
}

#[test]
fn a_notification_without_a_record_is_no_alert() {
    assert_eq!(alert("Build finished", "", Level::Info, &[]), None);
    let working = [record(State::Working, None, Some("Build"), None, 1)];
    assert_eq!(alert("Build is done", "", Level::Info, &working), None);
}

#[test]
fn the_newest_matching_record_wins() {
    let records = [
        record(State::Done, None, Some("Tests"), None, 3),
        record(State::Done, None, Some("Tests"), None, 9),
        record(State::Done, None, Some("Tests"), None, 9),
        record(State::Done, None, Some("Tests"), None, 2),
    ];
    assert_eq!(alert("Tests is done", "", Level::Info, &records).map(|found| found.index), Some(1));
}

#[test]
fn the_title_and_body_compare_at_the_daemons_limits() {
    let title = "t".repeat(300);
    let msg = "m".repeat(2000);
    let records = [record(State::Blocked, None, Some(&title), Some(&msg), 1)];
    let posted_title = "t".repeat(TITLE_LIMIT);
    let posted_body = "m".repeat(BODY_LIMIT);
    assert!(alert(&posted_title, &posted_body, Level::Warning, &records).is_some());
}

#[test]
fn a_title_reads_like_an_alert_at_its_verbs_level() {
    assert!(looks_like_alert("Claude needs input", Level::Warning));
    assert!(looks_like_alert("cargo failed", Level::Error));
    assert!(looks_like_alert("Tests is done", Level::Info));
    assert!(!looks_like_alert("Tests is done", Level::Warning), "the level must be the verb's");
    assert!(!looks_like_alert(" needs input", Level::Warning), "a name comes before the verb");
    assert!(!looks_like_alert("Build finished", Level::Info));
}

#[test]
fn done_notifies_only_for_a_hidden_terminal() {
    assert!(alert_notifies(Reason::Done, Visibility::default()));
    assert!(!alert_notifies(Reason::Done, VISIBLE));
    assert!(alert_notifies(Reason::Failed, VISIBLE));
    let mut away = VISIBLE;
    away.app_active = false;
    assert!(alert_notifies(Reason::Done, away), "every part of visibility counts");
}

fn entry(state: &str, duration_ms: Option<u64>) -> Entry {
    Entry {
        key: "run:42".into(),
        state: Some(state.into()),
        text: "Tests".into(),
        target_terminal: Some("term_7".into()),
        exit_code: (state != "busy").then_some(if state == "error" { 2 } else { 0 }),
        duration_ms,
    }
}

fn statuses(entries: Vec<Entry>) -> Vec<WorkspaceStatus> {
    vec![WorkspaceStatus { workspace: "ws_1".into(), entries }]
}

#[test]
fn a_run_seen_running_then_finished_counts_once() {
    let busy = update_runs(&[], &statuses(vec![entry("busy", None)]));
    assert!(busy.finished.is_empty(), "a running command notified");
    assert_eq!(busy.running, [Run { workspace: "ws_1".into(), key: "run:42".into() }]);
    let done = update_runs(&busy.running, &statuses(vec![entry("success", Some(12_000))]));
    assert_eq!(
        done.finished,
        [FinishedRun {
            workspace: "ws_1".into(),
            key: "run:42".into(),
            label: "Tests".into(),
            terminal: Some("term_7".into()),
            succeeded: true,
            exit_code: Some(0),
            duration_ms: Some(12_000),
        }]
    );
    assert!(done.running.is_empty());
    let mut lint = entry("success", None);
    lint.key = "lint".into();
    let again = update_runs(&done.running, &statuses(vec![entry("success", Some(12_000)), lint]));
    assert!(again.finished.is_empty(), "a finished run notifies once");
}

#[test]
fn a_failed_run_is_not_a_success() {
    let busy = update_runs(&[], &statuses(vec![entry("busy", None)]));
    let failed = update_runs(&busy.running, &statuses(vec![entry("error", Some(15_000))]));
    assert!(!failed.finished[0].succeeded);
    assert_eq!(failed.finished[0].exit_code, Some(2));
}

#[test]
fn a_run_never_seen_running_or_gone_while_busy_does_not_count() {
    assert!(update_runs(&[], &statuses(vec![entry("success", Some(60_000))])).finished.is_empty());
    let busy = update_runs(&[], &statuses(vec![entry("busy", None)]));
    let gone = update_runs(&busy.running, &statuses(vec![]));
    assert!(gone.finished.is_empty() && gone.running.is_empty());
    let mut other = entry("busy", None);
    other.key = "lint".into();
    assert!(
        update_runs(&[], &statuses(vec![other])).running.is_empty(),
        "only run: entries are runs"
    );
}

#[test]
fn a_run_shorter_than_the_minimum_does_not_notify() {
    let hidden = Visibility::default();
    assert!(!run_notifies(Some(9_000), RunBehavior::default(), hidden));
    assert!(run_notifies(Some(12_000), RunBehavior::default(), hidden));
    let five = RunBehavior { run_notify_minimum_seconds: 5.0, ..RunBehavior::default() };
    assert!(run_notifies(Some(9_000), five, hidden), "the minimum is the setting's");
    assert!(!run_notifies(None, RunBehavior::default(), hidden), "no duration counts as instant");
    let zero = RunBehavior { run_notify_minimum_seconds: 0.0, ..RunBehavior::default() };
    assert!(run_notifies(None, zero, hidden));
}

#[test]
fn a_visible_terminal_notifies_only_when_the_setting_says_so() {
    assert!(!run_notifies(Some(60_000), RunBehavior::default(), VISIBLE));
    let when_visible = RunBehavior { run_notify_when_visible: true, ..RunBehavior::default() };
    assert!(run_notifies(Some(60_000), when_visible, VISIBLE));
}
