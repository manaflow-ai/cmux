use std::cmp::Ordering;

use serde_json::json;

use super::ops::SftpFsOwner;
use super::sort::natural;
use super::*;
use crate::test_support::{LocalServer, sftp_server};

#[test]
fn relative_paths_cannot_leave_the_root() {
    assert_eq!(components("").unwrap(), Vec::<&str>::new());
    assert_eq!(components("a//b/").unwrap(), vec!["a", "b"]);
    for bad in ["/etc", "../x", "a/../../b", "a/./b"] {
        assert_eq!(components(bad), Err(FsError::NotInsideRoot), "{bad:?}");
    }
    assert_eq!(components("a\0b"), Err(FsError::NameInvalid));
    assert_eq!(check_name(&"x".repeat(256)), Err(FsError::NameInvalid));
}

#[test]
fn natural_order_is_case_insensitive_and_numeric() {
    let mut names = vec!["file10", "File2", "file1", "a", "B", "file02"];
    names.sort_by(|left, right| natural(left, right));
    assert_eq!(names, vec!["a", "B", "file1", "File2", "file02", "file10"]);
    assert_eq!(natural("x", "X"), "x".cmp("X"), "raw names break ties");
    assert_ne!(natural("file2", "file02"), Ordering::Equal);
    assert_eq!(mode_display(0o100_754), "rwxr-xr--");
}

struct Fixture {
    _home: tempfile::TempDir,
    root_path: std::path::PathBuf,
    server: LocalServer,
    root: SftpRoot,
}

async fn fixture(rights: Rights) -> Option<Fixture> {
    let server_binary = sftp_server()?;
    let home = tempfile::tempdir().unwrap();
    let root_path = home.path().join("root");
    std::fs::create_dir_all(root_path.join("docs/inner")).unwrap();
    std::fs::write(root_path.join("docs/a.txt"), "alpha").unwrap();
    std::fs::write(root_path.join("docs/b10.txt"), "b10").unwrap();
    std::fs::write(root_path.join("docs/b2.txt"), "b2").unwrap();
    std::fs::write(root_path.join("docs/.hidden"), "h").unwrap();
    std::fs::write(root_path.join("docs/bin.dat"), [0_u8, 159, 146, 150]).unwrap();
    std::fs::write(home.path().join("outside.txt"), "secret").unwrap();
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(home.path().join("outside.txt"), root_path.join("docs/escape"))
            .unwrap();
        std::os::unix::fs::symlink(root_path.join("docs/a.txt"), root_path.join("docs/inside"))
            .unwrap();
        std::os::unix::fs::symlink(home.path(), root_path.join("updir")).unwrap();
    }
    let server = LocalServer::start(&server_binary, home.path()).await;
    let root =
        SftpRoot::open(server.client.clone(), root_path.to_str().unwrap(), rights).await.unwrap();
    Some(Fixture { _home: home, root_path, server, root })
}

#[tokio::test]
async fn list_snapshots_sort_filter_and_page() {
    let Some(fixture) = fixture(Rights::Read).await else { return };
    let owner = SftpFsOwner::default();
    let first = owner
        .call(
            "app/conn",
            &fixture.root,
            "fs.list",
            json!({
                "conn": "conn_x", "root": "root_x", "path": "docs",
                "sort": {"key": "name", "dir": "asc", "dirs_first": true},
                "filter": {"hidden": false}, "limit": 3
            }),
        )
        .await
        .unwrap();
    let names: Vec<_> = first["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(names, vec!["inner", "a.txt", "b2.txt"]);
    assert_eq!(first["total"], 7, "hidden files are filtered out");
    let second = owner
        .call(
            "app/conn",
            &fixture.root,
            "fs.list",
            json!({
                "listing": first["listing"], "cursor": first["cursor"], "limit": 10
            }),
        )
        .await
        .unwrap();
    let rest: Vec<_> = second["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|entry| entry["name"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(rest, vec!["b10.txt", "bin.dat", "escape", "inside"]);
    assert!(second["cursor"].is_null());
    let escape = &second["entries"][2];
    assert_eq!(escape["kind"], "symlink");
    assert!(escape.get("target_kind").is_none(), "a link out of the root has no target kind");
    assert_eq!(second["entries"][3]["target_kind"], "file");
    assert_eq!(
        owner.call("app/conn", &fixture.root, "fs.watch", json!({})).await,
        Err(FsError::WatchUnsupported)
    );
}

#[tokio::test]
async fn symlinks_are_never_followed_out_of_the_root() {
    let Some(fixture) = fixture(Rights::ReadWrite).await else { return };
    let root = &fixture.root;
    assert_eq!(root.read("docs/escape", 0, 100).await, Err(FsError::NotInsideRoot));
    assert_eq!(root.read("updir/outside.txt", 0, 100).await, Err(FsError::NotInsideRoot));
    assert_eq!(root.read_directory("updir").await, Err(FsError::NotInsideRoot));
    assert_eq!(
        root.write("updir/new.txt", b"x", WriteMode::Create).await,
        Err(FsError::NotInsideRoot)
    );
    assert_eq!(root.read("../outside.txt", 0, 100).await, Err(FsError::NotInsideRoot));
    let stat = root.stat("docs/escape").await.unwrap();
    assert_eq!(stat.entry.kind, EntryKind::Symlink);
    assert_eq!(stat.entry.target_kind, None);
}

#[tokio::test]
async fn stat_and_read_report_text_and_binary() {
    let Some(fixture) = fixture(Rights::Read).await else { return };
    let root = &fixture.root;
    let stat = root.stat("docs/a.txt").await.unwrap();
    assert_eq!(stat.entry.size, Some(5));
    assert!(stat.revision.is_some());
    let text = root.read("docs/a.txt", 1, 3).await.unwrap();
    assert_eq!(text.text.as_deref(), Some("lph"));
    assert!(text.truncated);
    let binary = root.read("docs/bin.dat", 0, 1024).await.unwrap();
    assert_eq!(binary.encoding, "binary");
    assert_eq!(binary.bytes_base64.as_deref(), Some("AJ+Slg=="));
    assert!(!binary.truncated);
    assert_eq!(root.write("docs/x", b"x", WriteMode::Create).await, Err(FsError::ReadOnly));
    assert_eq!(root.read("docs/missing", 0, 1).await, Err(FsError::NotFound));
}

#[tokio::test]
async fn writes_are_atomic_and_honor_the_expected_revision() {
    let Some(fixture) = fixture(Rights::ReadWrite).await else { return };
    let root = &fixture.root;
    let big: Vec<u8> = (0..300_000_u32).map(|value| (value % 251) as u8).collect();
    let entry = root.write("docs/new.bin", &big, WriteMode::Create).await.unwrap();
    assert_eq!(entry.size, Some(big.len() as u64));
    assert_eq!(std::fs::read(fixture.root_path.join("docs/new.bin")).unwrap(), big);
    assert_eq!(root.write("docs/new.bin", b"x", WriteMode::Create).await, Err(FsError::Exists));

    let stale = Revision { size: 1, mtime: 1 };
    let mismatch =
        root.write("docs/a.txt", b"changed", WriteMode::Replace { expected: stale }).await;
    assert!(
        matches!(mismatch, Err(FsError::RevisionMismatch { current: Some(_) })),
        "{mismatch:?}"
    );
    assert_eq!(std::fs::read_to_string(fixture.root_path.join("docs/a.txt")).unwrap(), "alpha");

    let token = root.stat("docs/a.txt").await.unwrap().revision.unwrap();
    let (size, mtime) = token.trim_start_matches('s').split_once("-m").unwrap();
    let expected = Revision { size: size.parse().unwrap(), mtime: mtime.parse().unwrap() };
    root.write("docs/a.txt", b"replaced", WriteMode::Replace { expected }).await.unwrap();
    assert_eq!(std::fs::read_to_string(fixture.root_path.join("docs/a.txt")).unwrap(), "replaced");

    let leftovers: Vec<_> = std::fs::read_dir(fixture.root_path.join("docs"))
        .unwrap()
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .filter(|name| name.ends_with(".tmp"))
        .collect();
    assert!(leftovers.is_empty(), "no temporary files remain: {leftovers:?}");
}

#[tokio::test]
async fn mkdir_rename_remove_and_trash() {
    let Some(fixture) = fixture(Rights::ReadWrite).await else { return };
    let owner = SftpFsOwner::default();
    let root = &fixture.root;
    let call = |op: &'static str, params| owner.call("app/conn", root, op, params);
    let made = call("fs.mkdir", json!({"path": "docs", "name": "made"})).await.unwrap();
    assert_eq!(made["entry"]["kind"], "dir");
    assert_eq!(
        call("fs.mkdir", json!({"path": "docs", "name": "made"})).await,
        Err(FsError::Exists)
    );
    assert_eq!(
        call("fs.mkdir", json!({"path": "docs", "name": "../x"})).await,
        Err(FsError::NameInvalid)
    );
    call("fs.rename", json!({"path": "docs/made", "name": "renamed"})).await.unwrap();
    assert!(fixture.root_path.join("docs/renamed").is_dir());
    assert_eq!(
        call("fs.rename", json!({"path": "docs/b2.txt", "name": "a.txt"})).await,
        Err(FsError::Exists)
    );
    call("fs.write", json!({"path": "docs/renamed/w.txt", "text": "w", "mode": "create"}))
        .await
        .unwrap();
    assert_eq!(root.remove("docs/renamed").await, Err(FsError::NotEmpty));
    call("fs.delete", json!({"paths": ["docs/renamed"], "permanent": true})).await.unwrap();
    assert!(!fixture.root_path.join("docs/renamed").exists());
    assert_eq!(
        root.remove("").await,
        Err(FsError::NameInvalid),
        "the root itself is never removed"
    );

    let trashed = call("fs.trash", json!({"paths": ["docs/b10.txt"]})).await.unwrap();
    let job = trashed["job"].as_str().unwrap();
    assert!(!fixture.root_path.join("docs/b10.txt").exists());
    let home = fixture.root_path.parent().unwrap();
    assert_eq!(
        std::fs::read_to_string(home.join(".cmux-trash").join(job).join("b10.txt")).unwrap(),
        "b10"
    );
    drop(fixture.server);
}

#[test]
fn temporary_names_stay_within_255_bytes() {
    let long = "é".repeat(127);
    let name = temporary_name(&long);
    assert!(name.len() <= 255, "{}", name.len());
    assert!(name.starts_with(".é") && name.ends_with(".tmp"));
    assert!(temporary_name("a.txt").starts_with(".a.txt.cmux-"));
}

#[tokio::test]
async fn a_cancelled_write_leaves_the_stream_usable_and_no_waiters() {
    let Some(fixture) = fixture(Rights::ReadWrite).await else { return };
    let client = fixture.server.client.clone();
    let path = fixture.root_path.join("docs/cancel.bin");
    let handle = client
        .open(
            path.to_str().unwrap(),
            crate::sftp::proto::SSH_FXF_WRITE | crate::sftp::proto::SSH_FXF_CREAT,
            &Attrs::default(),
        )
        .await
        .unwrap();
    for _ in 0..20 {
        let data = bytes::Bytes::from(vec![1_u8; 4 * 1024 * 1024]);
        let write = remote::write_all(&client, &handle, 0, data);
        let _ = tokio::time::timeout(std::time::Duration::from_micros(300), write).await;
        // Every packet is whole: the next request still gets its own reply.
        client.realpath(".").await.expect("the stream is still in step");
    }
    client.close(&handle).await.unwrap();
    for _ in 0..100 {
        if client.pending_requests() == 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert_eq!(client.pending_requests(), 0, "cancelled requests leave no waiters");
}

#[tokio::test]
async fn directory_reads_are_capped() {
    let Some(fixture) = fixture(Rights::Read).await else { return };
    let path = fixture.root_path.join("docs");
    let result = fixture.server.client.read_dir(path.to_str().unwrap(), 3).await;
    assert_eq!(result, Err(SftpError::TooManyEntries));
}

#[tokio::test]
async fn names_with_control_characters_are_dropped_from_listings() {
    let Some(fixture) = fixture(Rights::Read).await else { return };
    std::fs::write(fixture.root_path.join("docs/bad\nname"), "x").unwrap();
    let (entries, _) = fixture.root.read_directory("docs").await.unwrap();
    assert!(entries.iter().all(|entry| !entry.name.contains('\n')));
    assert!(entries.iter().any(|entry| entry.name == "a.txt"));
}

#[tokio::test]
async fn replace_without_posix_rename_is_refused_and_keeps_both_files() {
    let Some(fixture) = fixture(Rights::ReadWrite).await else { return };
    fixture.server.client.forget_extension("posix-rename@openssh.com");
    let result = fixture.root.write("docs/a.txt", b"new", WriteMode::Overwrite).await;
    assert_eq!(result, Err(FsError::ReplaceUnsupported));
    assert_eq!(std::fs::read_to_string(fixture.root_path.join("docs/a.txt")).unwrap(), "alpha");
    let temporary = std::fs::read_dir(fixture.root_path.join("docs"))
        .unwrap()
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .any(|name| name.ends_with(".tmp"));
    assert!(!temporary, "the temporary file is removed");
    // A new file still works: plain rename never replaces.
    fixture.root.write("docs/fresh.txt", b"x", WriteMode::Create).await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn replaced_files_never_keep_setuid_or_sticky_bits() {
    use std::os::unix::fs::PermissionsExt as _;
    let Some(fixture) = fixture(Rights::ReadWrite).await else { return };
    let path = fixture.root_path.join("docs/a.txt");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o4755)).unwrap();
    fixture.root.write("docs/a.txt", b"new", WriteMode::Overwrite).await.unwrap();
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o7777;
    assert_eq!(mode & 0o7000, 0, "mode {mode:o}");
}
