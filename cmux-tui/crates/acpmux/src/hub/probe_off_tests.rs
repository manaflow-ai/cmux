//! Model probes against MDM's off that comes and goes as they begin (review 77 of #23322), and
//! the one blank-id rule at every place a session id enters the full-access bound (`known_id`).

use super::*;

/// Review 77 of #23322: an MDM off that comes and goes while a model probe reads it is the
/// probe's, so a profile pinning full access is never started.
#[tokio::test]
async fn a_pinned_probe_never_starts_after_an_off_that_came_and_went_as_it_began() {
    let dir = std::env::temp_dir().join(format!("acpmux-probe-off-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let marker = dir.join("started");
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let argv = ["sh", "-c", "echo $$ > \"$0\"; exec python3 \"$1\"", "", fake, "--yolo"];
    let mut argv: Vec<String> = argv.iter().map(|a| (*a).to_owned()).collect();
    argv[3] = marker.to_string_lossy().into_owned();
    let profile: HarnessProfile = serde_json::from_value(json!({"argv": argv})).unwrap();
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let came_and_went: fn(&Hub) = |hub| {
        hub.update_start_mode_state(None, |s| s.full_access_managed = Some(false));
        hub.update_start_mode_state(None, |s| s.full_access_managed = None);
    };
    super::super::full_access_bound::AFTER_OFF_COUNT.set(Some(came_and_went));
    let probed = hub.probe_one("pinned", &profile).await;
    let started = marker.exists();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(probed.is_err(), "the pinned probe kept its models");
    assert!(!started, "a profile pinning full access started after the off came and went");
}

/// Reviews 70 and 74 of #23322: an empty or all-whitespace session id names no session at every
/// place one enters the full-access bound (`full_access_bound::known_id`): a report's, a
/// `session/new` answer's, a probe's and a pooled agent's. Each blank id makes any report of full
/// access count.
#[tokio::test]
async fn a_blank_session_id_names_no_session_at_every_entry() {
    use super::super::full_access_bound::{StartReports, known_id};
    let report = |sid: &str| {
        json!({"sessionId": sid, "update": {"sessionUpdate": "current_mode_update",
                                             "currentModeId": "bypassPermissions"}})
    };
    for blank in ["", " ", "\t\n"] {
        assert_eq!(known_id(Some(blank)), None, "{blank:?} named a session");
        // A report under a blank id counts for every session.
        let mut reports = StartReports::default();
        reports.note(&report(blank));
        assert!(reports.of(Some("fake-1")), "report: a report under {blank:?} did not count");
        // Another session's report counts for a harness session whose answer names a blank id.
        let mut reports = StartReports::default();
        reports.note(&report("fake-other"));
        let answer = json!({"sessionId": blank});
        assert!(reports.of_answer(Some(&answer)), "session/new: {blank:?} was a known session");
        // A pooled agent's held lines, read against its answer.
        let held = vec![(
            Direction::In,
            Message::Notification {
                method: method::SESSION_UPDATE.to_owned(),
                params: Some(report("fake-other")),
            },
            None,
        )];
        assert!(
            super::super::pool::held_reports_full_access(&held, Some(&answer)),
            "pool: {blank:?} was a known session"
        );
    }
    assert_eq!(known_id(Some("fake-1")), Some("fake-1"));
    let mut other = StartReports::default();
    other.note(&report("fake-other"));
    assert!(!other.of(Some("fake-1")), "another session's report counted for a known one");
    // A probe whose harness answers with a blank id and reports full access for another session
    // keeps nothing under MDM's off.
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let argv = [
        "/usr/bin/env",
        "FAKE_NO_MODES=1",
        "FAKE_STARTUP_MODE=bypassPermissions",
        "FAKE_STARTUP_SID=fake-other",
        "FAKE_NEW_RESULT_SID= ",
        "python3",
        fake,
    ];
    let profile: HarnessProfile = serde_json::from_value(json!({"argv": argv})).unwrap();
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.apply_full_access_push(Some(false)).await;
    let probed = hub.probe_one("blank", &profile).await;
    let refused = probed.as_ref().is_err_and(|e| format!("{e:#}").contains("full access"));
    assert!(refused, "probe: a blank answer id hid a report of full access: {probed:?}");
}
