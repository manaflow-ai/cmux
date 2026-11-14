use super::*;

#[test]
fn cloud_repo_local_parses_github_remotes_without_transmitting_credentials() {
    for remote in [
        "https://github.com/Manaflow-AI/cmux.git",
        "git@github.com:Manaflow-AI/cmux.git",
        "ssh://git@github.com/Manaflow-AI/cmux.git",
    ] {
        assert_eq!(github_name(remote).as_deref(), Some("Manaflow-AI/cmux"));
    }
    for remote in [
        "https://github.com.attacker.test/o/r.git",
        "https://github.com@attacker.test/o/r.git",
        "https://secret@github.com/o/r.git",
        "https://u:secret@github.com/o/r.git",
        "https://github.com/o/r?token=secret",
        "https://github.com/o/r#secret",
        "git@github.com:o/../r",
        "git@github.com:o/r\nsecret",
        "file:///tmp/o/r",
        "https://gitlab.com/o/r",
    ] {
        assert_eq!(github_name(remote), None, "{remote}");
    }
}

#[test]
fn cloud_repo_local_keeps_project_priority_and_all_github_remotes() {
    let result = catalog(&["recent", "missing", "older"], |path| {
        match path {
            "recent" => RemoteRead::Config(
                b"remote.origin.url\ngit@github.com:o/r.git\0remote.upstream.url\nhttps://github.com/upstream/r.git\0".to_vec(),
            ),
            "missing" => RemoteRead::Absent,
            _ => RemoteRead::Config(
                b"remote.origin.url\nhttps://github.com/O/R.git\0remote.extra.url\nhttps://github.com/other/tool.git\0".to_vec(),
            ),
        }
    });
    assert_eq!(result["complete"], true);
    assert_eq!(
        result["repos"],
        json!([
            {"fullName":"o/r", "private":true, "source":"local"},
            {"fullName":"upstream/r", "private":true, "source":"local"},
            {"fullName":"other/tool", "private":true, "source":"local"}
        ])
    );
    assert!(!result.to_string().contains("older"));
}

#[test]
fn cloud_repo_local_never_presents_timed_out_scan_as_complete() {
    let mut reads = 0;
    let result = catalog(&["slow", "later"], |_| {
        reads += 1;
        RemoteRead::Incomplete
    });
    assert_eq!(reads, 1);
    assert_eq!(result, json!({"repos":[],"complete":false}));
}

#[test]
fn cloud_repo_local_deleted_recent_folder_does_not_block_catalog() {
    let path = std::env::temp_dir()
        .join(format!("cmux-repo-deleted-{}", crate::workspace_registry::new_uuid_v4()));
    std::fs::create_dir(&path).unwrap();
    std::fs::remove_dir(&path).unwrap();
    let result = catalog(&[path.to_str().unwrap()], |path| {
        read_remote(path, Instant::now() + CATALOG_DEADLINE)
    });
    assert_eq!(result, json!({"repos":[],"complete":true}));
}
