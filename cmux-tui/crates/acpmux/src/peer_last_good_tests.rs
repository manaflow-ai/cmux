use super::*;
use std::time::Duration;

#[test]
fn the_last_good_path_is_read_again_after_a_restart_and_dialed_first() {
    let dir = tempfile::tempdir().unwrap();
    let book = LastGood::open(Some(dir.path()));
    let mut paths = Paths::new(&[Via::Ssh, Via::Link]);
    paths.pong(Via::Ssh, Duration::from_millis(40), 0);
    paths.pong(Via::Ssh, Duration::from_millis(40), 3_000);
    let endpoints =
        Endpoints { url: Some("ssh://mini".into()), link: Some("inst_b".into()), wireguard: None };
    book.record("mini", Entry::of(&paths, Via::Ssh, endpoints.clone(), 3_000));
    drop(book);

    // A new daemon run.
    let book = LastGood::open(Some(dir.path()));
    let entry = book.get("mini").expect("kept across the restart");
    assert_eq!(entry.via, Some(Via::Ssh));
    assert_eq!(entry.carrier.as_deref(), Some("ssh"));
    assert_eq!(entry.endpoints, endpoints);
    assert_eq!(entry.rtt_ms.get("ssh"), Some(&40.0));
    let mut fresh = Paths::new(&[Via::Ssh, Via::Link]);
    assert_eq!(fresh.dial_order(0), vec![Via::Link, Via::Ssh]);
    fresh.remember(entry.via);
    assert_eq!(fresh.dial_order(0), vec![Via::Ssh, Via::Link], "the remembered path first");

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(dir.path().join(FILE_NAME)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    book.forget("mini");
    assert!(LastGood::open(Some(dir.path())).get("mini").is_none());
}

#[test]
fn a_file_of_another_version_or_garbage_reads_as_empty() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join(FILE_NAME), br#"{"version":2,"peers":{"a":{}}}"#).unwrap();
    assert!(LastGood::open(Some(dir.path())).get("a").is_none());
    std::fs::write(dir.path().join(FILE_NAME), b"not json").unwrap();
    assert!(LastGood::open(Some(dir.path())).get("a").is_none());
    let memory = LastGood::open(None);
    memory.record("a", Entry { via: Some(Via::Link), ..Entry::default() });
    assert_eq!(memory.get("a").and_then(|e| e.via), Some(Via::Link));
}
