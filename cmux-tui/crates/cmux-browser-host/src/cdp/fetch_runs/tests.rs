use super::*;

#[test]
fn a_finished_fetch_leaves_no_entry() {
    let mut runs = Runs::default();
    let now = Instant::now();
    assert!(runs.start("f1", now));
    assert!(!runs.set_target("f1", "T1"));
    runs.finish("f1");
    assert_eq!(runs.len(), 0);
}

#[test]
fn a_cancel_that_came_first_fails_the_fetch_when_it_starts() {
    let mut runs = Runs::default();
    let now = Instant::now();
    assert_eq!(runs.cancel("f1", now), None);
    assert!(!runs.start("f1", now), "the fetch fails at once");
    assert_eq!(runs.len(), 0, "the early cancel is used up");
}

#[test]
fn a_running_fetch_is_cancelled_in_its_tab() {
    let mut runs = Runs::default();
    let now = Instant::now();
    assert!(runs.start("f1", now));
    assert!(!runs.set_target("f1", "T1"));
    assert_eq!(runs.cancel("f1", now), Some("T1".to_owned()));
    assert!(runs.is_cancelled("f1"));
    runs.finish("f1");
    assert_eq!(runs.len(), 0);
}

/// No per-fetch leak: a cancel that came after its fetch returned is
/// swept by a later call.
#[test]
fn a_late_cancel_is_swept() {
    let mut runs = Runs::default();
    let now = Instant::now();
    assert!(runs.start("f1", now));
    runs.finish("f1");
    assert_eq!(runs.cancel("f1", now), None);
    let later = now + EARLY_CANCEL_TTL + Duration::from_secs(1);
    assert!(runs.start("f2", later));
    runs.finish("f2");
    assert_eq!(runs.len(), 0, "the late cancel stayed");
}
