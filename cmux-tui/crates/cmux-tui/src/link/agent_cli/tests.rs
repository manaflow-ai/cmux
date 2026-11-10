use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

const BASE: &[&str] =
    &["move", "--from-socket", "/a", "--surface", "7", "--to-socket", "/b", "--cwd", "/w"];

fn parsed(extra: &[&str]) -> Option<Args> {
    parse(&args(&[BASE, extra].concat()))
}

fn shape(sync: &Sync) -> (bool, bool, String, String, String) {
    let way = (sync.way == Way::Pull, sync.way == Way::Seed);
    (
        way.0,
        way.1,
        sync.socket.display().to_string(),
        sync.local.display().to_string(),
        sync.remote.clone(),
    )
}

#[test]
fn no_sync_and_one_sync_parse_as_before() {
    assert!(parsed(&[]).is_some_and(|a| a.syncs.is_empty()));
    let one = parsed(&[
        "--sync-local",
        "/l",
        "--sync",
        "seed",
        "--sync-remote",
        "/r/",
        "--sync-socket",
        "/s",
    ])
    .expect("one group, flags in any order");
    assert_eq!(
        one.syncs.iter().map(shape).collect::<Vec<_>>(),
        [(false, true, "/s".to_owned(), "/l".to_owned(), "/r".to_owned())]
    );
}

#[test]
fn a_second_sync_group_runs_after_the_first() {
    let two = parsed(&[
        "--sync",
        "pull",
        "--sync-socket",
        "/old",
        "--sync-local",
        "/l",
        "--sync-remote",
        "/r1",
        "--sync",
        "seed",
        "--sync-socket",
        "/new",
        "--sync-local",
        "/l",
        "--sync-remote",
        "/r2",
    ])
    .expect("two groups");
    assert_eq!(
        two.syncs.iter().map(shape).collect::<Vec<_>>(),
        [
            (true, false, "/old".to_owned(), "/l".to_owned(), "/r1".to_owned()),
            (false, true, "/new".to_owned(), "/l".to_owned(), "/r2".to_owned()),
        ]
    );
}

#[test]
fn an_incomplete_or_relative_group_is_bad_usage() {
    assert!(parsed(&["--sync", "seed", "--sync-socket", "/s", "--sync-local", "/l"]).is_none());
    assert!(
        parsed(&[
            "--sync",
            "seed",
            "--sync-socket",
            "/s",
            "--sync-local",
            "/l",
            "--sync-remote",
            "r"
        ])
        .is_none()
    );
    // A second group missing its remote.
    assert!(
        parsed(&[
            "--sync",
            "pull",
            "--sync-socket",
            "/a",
            "--sync-local",
            "/l",
            "--sync-remote",
            "/r",
            "--sync",
            "seed",
            "--sync-socket",
            "/b",
            "--sync-local",
            "/l",
        ])
        .is_none()
    );
}
