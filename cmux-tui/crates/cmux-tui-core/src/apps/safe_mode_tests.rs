use super::*;

const MIN: u64 = 60 * 1000;

fn fail(launches: &mut Launches, at: u64, app: &str) -> Option<Vec<String>> {
    let tripped = launches.began(at);
    launches.mounted(app);
    tripped
}

#[test]
fn three_failed_launches_in_five_minutes_trip_the_next_one() {
    let mut launches = Launches::default();
    assert_eq!(fail(&mut launches, 10 * MIN, "acme/a"), None);
    assert_eq!(fail(&mut launches, 11 * MIN, "acme/b"), None);
    assert_eq!(fail(&mut launches, 12 * MIN, "acme/a"), None);
    // The fourth launch sees three that never settled.
    assert_eq!(launches.began(13 * MIN), Some(vec!["acme/a".into(), "acme/b".into()]));
    // Tripping used them up.
    assert!(launches.failed.is_empty());
    assert_eq!(launches.began(14 * MIN), None);
}

#[test]
fn a_settled_launch_resets_the_count() {
    let mut launches = Launches::default();
    fail(&mut launches, MIN, "acme/a");
    fail(&mut launches, 2 * MIN, "acme/a");
    launches.began(3 * MIN);
    launches.settled();
    assert_eq!(launches.began(4 * MIN), None);
    assert_eq!(launches.began(5 * MIN), None);
    assert_eq!(launches.began(6 * MIN), None, "only two failed since the settle");
    assert!(launches.began(7 * MIN).is_some());
}

#[test]
fn a_clean_quit_does_not_count() {
    let mut launches = Launches::default();
    for minute in 1..=5 {
        assert_eq!(launches.began(minute * MIN), None);
        // `launch_settled {reason: quit}` settles like a first frame.
        launches.settled();
    }
    assert!(launches.failed.is_empty());
}

#[test]
fn failures_older_than_the_window_do_not_count() {
    let mut launches = Launches::default();
    fail(&mut launches, MIN, "acme/a");
    fail(&mut launches, 2 * MIN, "acme/a");
    fail(&mut launches, 3 * MIN, "acme/a");
    // Six minutes after the first failure only two are in the window.
    assert_eq!(launches.began(6 * MIN + 1), None);
}

#[test]
fn clock_skew_never_invents_a_loop() {
    let mut launches = Launches::default();
    fail(&mut launches, 100 * MIN, "acme/a");
    fail(&mut launches, 101 * MIN, "acme/a");
    fail(&mut launches, 102 * MIN, "acme/a");
    // The clock went back an hour: stamps after now are dropped.
    assert_eq!(launches.began(40 * MIN), None);
    assert!(launches.failed.is_empty());
    // The clock went forward a day: everything is outside the window.
    let mut launches = Launches::default();
    fail(&mut launches, MIN, "acme/a");
    fail(&mut launches, 2 * MIN, "acme/a");
    fail(&mut launches, 3 * MIN, "acme/a");
    assert_eq!(launches.began(24 * 60 * MIN), None);
}

#[test]
fn the_record_stays_bounded() {
    let mut launches = Launches::default();
    // Each launch trips on the fourth; between trips the list never grows past the cap.
    for second in 0..100 {
        launches.began(second * 1000);
        assert!(launches.failed.len() <= KEPT_FAILURES);
    }
}

#[test]
fn the_flag_file_wins_over_the_env_and_off_is_off() {
    let dir = std::env::temp_dir().join(format!("cmux-safe-mode-initial-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = safe_mode_flag::path_in(&dir);
    let _ = std::fs::remove_file(&path);
    assert_eq!(initial(Some(&path), false), None);
    assert_eq!(initial(Some(&path), true).map(|f| f.reason), Some(Reason::Env));
    let user = Flag { on: true, reason: Reason::User, since_ms: 5, extensions: vec![] };
    safe_mode_flag::write(&path, Some(&user)).unwrap();
    assert_eq!(initial(Some(&path), true), Some(user));
    std::fs::remove_dir_all(&dir).unwrap();
}
