use std::sync::mpsc::{Receiver, channel};

use super::*;

const SHORT: Duration = Duration::from_millis(80);
const NONE_WITHIN: Duration = Duration::from_millis(400);

fn away() -> (Arc<Away>, Receiver<Report>) {
    let (sender, receiver) = channel();
    let sender = Mutex::new(sender);
    let away = Away::with_gather(SHORT, move |report| {
        let _ = sender.lock().unwrap().send(report);
    });
    (away, receiver)
}

#[test]
fn an_episode_is_told_once_however_many_reads_fail() {
    let (away, reports) = away();
    for _ in 0..3 {
        away.failed("src/a.rs");
        away.failed("src/b.rs");
        away.failed("README.md");
    }
    let report = reports.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(report.episode, 1);
    assert_eq!(report.paths, ["README.md", "src/a.rs", "src/b.rs"]);
    assert_eq!(report.failed, 3);
    assert!(!report.back);
    // Reads that fail after the report, in the same episode, tell nothing more.
    away.failed("src/c.rs");
    away.failed("src/a.rs");
    assert!(reports.recv_timeout(NONE_WITHIN).is_err());
}

#[test]
fn a_report_names_at_most_max_paths_and_counts_the_rest() {
    let (away, reports) = away();
    for at in 0..MAX_PATHS + 7 {
        away.failed(&format!("f{at:03}"));
    }
    let report = reports.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(report.paths.len(), MAX_PATHS);
    assert_eq!(report.paths.first().map(String::as_str), Some("f000"));
    assert_eq!(report.failed, MAX_PATHS + 7);
    assert!(reports.recv_timeout(NONE_WITHIN).is_err());
}

#[test]
fn a_reconnect_ends_the_episode_and_the_next_away_is_told_again() {
    let (away, reports) = away();
    away.failed("a");
    assert_eq!(reports.recv_timeout(Duration::from_secs(5)).unwrap().episode, 1);
    away.back();
    away.failed("b");
    let second = reports.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(
        (second.episode, second.paths.as_slice(), second.back),
        (2, &["b".to_owned()][..], false)
    );
}

#[test]
fn a_reconnect_while_gathering_still_tells_and_says_it_is_back() {
    let (away, reports) = away();
    away.failed("a");
    away.back();
    let report = reports.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(report.back);
    // That episode is over: the next failure is a new one.
    away.failed("b");
    assert_eq!(reports.recv_timeout(Duration::from_secs(5)).unwrap().episode, 2);
}
