use super::*;

fn tokens(token: &str, peer: &str) -> Tokens {
    (token.into(), Some(peer.into()))
}

#[test]
fn retiring_writers_releases_the_gate_without_revoking_the_replacement() {
    let kept = KeptTokens::open(None);
    let (old, _) = kept.bind("box", "ssh://box");
    let (current, _) = kept.bind("box", "ssh://box");
    current.activate();
    kept.release("box", old);
    kept.keep_current("box", "ssh://box", &current, &tokens("new", "peer"));
    assert_eq!(kept.get("box", "ssh://box"), Some(tokens("new", "peer")));
    kept.release("box", current);
    assert!(kept.owners.lock().unwrap().is_empty());
}

#[test]
fn kept_tokens_are_read_again_after_a_restart_for_the_same_url_only() {
    let dir = tempfile::tempdir().unwrap();
    let kept = KeptTokens::open(Some(dir.path()));
    kept.keep("mini", "ssh://mini", &tokens("dash", "peer"));
    kept.keep("none", "ssh://none", &("dash".into(), None));
    drop(kept);

    // A new daemon run.
    let kept = KeptTokens::open(Some(dir.path()));
    assert_eq!(kept.get("mini", "ssh://mini"), Some(tokens("dash", "peer")));
    assert_eq!(kept.get("mini", "ssh://other"), None, "another URL reads again");
    assert_eq!(kept.get("none", "ssh://none"), None, "a read with no peer token is not kept");
    assert!(!format!("{kept:?}").contains("dash"), "Debug names no token");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(dir.path().join(FILE_NAME)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}

#[test]
fn forget_removes_the_entry_from_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let kept = KeptTokens::open(Some(dir.path()));
    kept.keep("a", "ssh://a", &tokens("dash-a", "peer-a"));
    kept.keep("b", "ssh://b", &tokens("dash-b", "peer-b"));
    kept.forget("a", "ssh://elsewhere");
    assert_eq!(
        kept.get("a", "ssh://a"),
        Some(tokens("dash-a", "peer-a")),
        "another URL's forget keeps it"
    );
    kept.forget("a", "ssh://a");
    let text = std::fs::read_to_string(dir.path().join(FILE_NAME)).unwrap();
    assert!(!text.contains("dash-a") && !text.contains("peer-a"), "{text}");
    let kept = KeptTokens::open(Some(dir.path()));
    assert_eq!(kept.get("a", "ssh://a"), None);
    assert_eq!(kept.get("b", "ssh://b"), Some(tokens("dash-b", "peer-b")));
}

#[test]
fn a_start_drops_the_tokens_of_peers_no_longer_configured() {
    let dir = tempfile::tempdir().unwrap();
    let kept = KeptTokens::open(Some(dir.path()));
    kept.keep("stays", "ssh://stays", &tokens("dash-s", "peer-s"));
    kept.keep("removed", "ssh://removed", &tokens("dash-r", "peer-r"));
    kept.keep("moved", "ssh://old", &tokens("dash-m", "peer-m"));
    drop(kept);

    // The next run, configured with `stays` and `moved` at a new URL.
    let kept = KeptTokens::open(Some(dir.path()));
    kept.retain([("stays", "ssh://stays"), ("moved", "ssh://new")]);
    let text = std::fs::read_to_string(dir.path().join(FILE_NAME)).unwrap();
    for gone in ["dash-r", "peer-r", "dash-m", "peer-m"] {
        assert!(!text.contains(gone), "{gone} outlived its peer: {text}");
    }
    let kept = KeptTokens::open(Some(dir.path()));
    assert_eq!(kept.get("stays", "ssh://stays"), Some(tokens("dash-s", "peer-s")));
    assert_eq!(kept.get("removed", "ssh://removed"), None);
}

#[test]
fn a_file_of_another_version_or_garbage_reads_as_empty() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(FILE_NAME);
    let entry = r#"{"url":"ssh://a","token":"t","peerToken":"p"}"#;
    std::fs::write(&path, format!(r#"{{"version":2,"peers":{{"a":{entry}}}}}"#)).unwrap();
    assert_eq!(KeptTokens::open(Some(dir.path())).get("a", "ssh://a"), None);
    std::fs::write(&path, b"not json").unwrap();
    assert_eq!(KeptTokens::open(Some(dir.path())).get("a", "ssh://a"), None);
    std::fs::write(&path, format!(r#"{{"version":1,"peers":{{"a":{entry}}}}}"#)).unwrap();
    assert_eq!(KeptTokens::open(Some(dir.path())).get("a", "ssh://a"), Some(tokens("t", "p")));
    let memory = KeptTokens::open(None);
    memory.keep("a", "ssh://a", &tokens("t", "p"));
    assert_eq!(memory.get("a", "ssh://a"), Some(tokens("t", "p")));
}
