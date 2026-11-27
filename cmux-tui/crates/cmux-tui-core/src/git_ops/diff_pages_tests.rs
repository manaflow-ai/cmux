use super::*;
use cmux_git::run::run_git_window_within;
use serde_json::json;

fn capture(window: &GitWindow, revision: &str) -> Capture {
    Capture { revision: revision.to_owned(), window: window.clone() }
}

#[test]
fn captures_are_scope_bound_count_bounded_and_expire_when_idle() {
    let window = run_git_window_within(
        &std::env::temp_dir(),
        &[],
        &["--version"],
        0,
        512,
        Duration::from_secs(2),
    )
    .unwrap()
    .window
    .unwrap();
    let revision = window.sha256.clone();
    let now = Instant::now();
    let mut cache = Captures::default();
    for index in 0..MAX_CAPTURES + 2 {
        cache.put(
            format!("repository/path/{index}"),
            capture(&window, &revision),
            json!({"index":index}),
            now + Duration::from_millis(index as u64),
        );
    }
    assert_eq!(cache.0.len(), MAX_CAPTURES);
    assert!(cache.get("repository/path/0", &revision, now + Duration::from_secs(1)).is_none());
    assert!(cache.get("another/repository/9", &revision, now + Duration::from_secs(1)).is_none());
    assert!(
        cache.get("repository/path/9", "wrong revision", now + Duration::from_secs(1)).is_none()
    );
    assert!(cache.get("repository/path/9", &revision, now + Duration::from_secs(1)).is_some());
    cache.prune(now + IDLE + Duration::from_secs(2));
    assert!(cache.0.is_empty());
}

#[test]
fn captures_keep_distinct_revisions_for_the_same_request() {
    let first = run_git_window_within(
        &std::env::temp_dir(),
        &[],
        &["--version"],
        0,
        512,
        Duration::from_secs(2),
    )
    .unwrap()
    .window
    .unwrap();
    let second = run_git_window_within(
        &std::env::temp_dir(),
        &[],
        &["--exec-path"],
        0,
        512,
        Duration::from_secs(2),
    )
    .unwrap()
    .window
    .unwrap();
    assert_ne!(first.sha256, second.sha256);

    let now = Instant::now();
    let mut cache = Captures::default();
    cache.put(
        "same request".into(),
        capture(&first, &first.sha256),
        json!({"revision":"first"}),
        now,
    );
    cache.put(
        "same request".into(),
        capture(&second, &second.sha256),
        json!({"revision":"second"}),
        now + Duration::from_millis(1),
    );

    assert_eq!(cache.0.len(), 2);
    assert_eq!(
        cache.get("same request", &first.sha256, now + Duration::from_millis(2)).unwrap().1,
        json!({"revision":"first"})
    );
    assert_eq!(
        cache.get("same request", &second.sha256, now + Duration::from_millis(2)).unwrap().1,
        json!({"revision":"second"})
    );
}

#[test]
fn same_patch_with_a_different_listing_keeps_each_listing_with_its_revision() {
    // BLOCK at 659ca591: an identical patch whose page-zero listing changed
    // (`complete` flipped by an oversized untracked file) replayed the
    // first listing on continuations of the second page zero.
    let window = run_git_window_within(
        &std::env::temp_dir(),
        &[],
        &["--version"],
        0,
        512,
        Duration::from_secs(2),
    )
    .unwrap()
    .window
    .unwrap();
    let now = Instant::now();
    let mut cache = Captures::default();
    cache.put("same request".into(), capture(&window, "complete"), json!({"complete":true}), now);
    cache.put(
        "same request".into(),
        capture(&window, "incomplete"),
        json!({"complete":false}),
        now + Duration::from_millis(1),
    );
    cache.put(
        "same request".into(),
        capture(&window, "incomplete"),
        json!({"complete":true}),
        now + Duration::from_millis(2),
    );
    assert_eq!(cache.0.len(), 2);
    let later = now + Duration::from_millis(3);
    assert_eq!(cache.get("same request", "complete", later).unwrap().1, json!({"complete":true}));
    assert_eq!(
        cache.get("same request", "incomplete", later).unwrap().1,
        json!({"complete":false})
    );
}
