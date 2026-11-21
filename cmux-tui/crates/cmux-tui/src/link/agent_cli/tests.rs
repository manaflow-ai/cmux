use super::*;
use std::path::Path;

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

#[test]
fn a_relay_group_names_both_machines_and_its_seed() {
    let relay = [
        "--sync",
        "relay",
        "--sync-from-socket",
        "/one",
        "--sync-socket",
        "/two",
        "--sync-local",
        "/home/a",
        "--sync-remote",
        "/home/b",
        "--sync-seed-local",
        "/Users/me/app",
    ];
    let one = parsed(&relay).expect("a relay group");
    let sync = one.syncs.first().expect("one group");
    assert!(sync.way == Way::Relay);
    assert_eq!(sync.from_socket.as_deref(), Some(Path::new("/one")));
    assert_eq!(sync.seed_local.as_deref(), Some(Path::new("/Users/me/app")));
    // A relay without its source, and a seed record on anything but a relay, are bad usage.
    let no_source: Vec<&str> =
        relay.iter().copied().filter(|w| *w != "--sync-from-socket" && *w != "/one").collect();
    assert!(parsed(&no_source).is_none());
    assert!(
        parsed(&[
            "--sync",
            "seed",
            "--sync-socket",
            "/s",
            "--sync-local",
            "/l",
            "--sync-remote",
            "/r",
            "--sync-seed-local",
            "/m"
        ])
        .is_none()
    );
}
