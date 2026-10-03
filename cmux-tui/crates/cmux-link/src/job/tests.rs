use std::path::Path;

use super::*;
use crate::fs::Rights;
use crate::test_support::{LocalServer, sftp_server};

async fn finish(handle: &mut JobHandle) -> Vec<JobEventKind> {
    let mut events = Vec::new();
    let mut last_seq = 0;
    while let Some(event) = handle.events.recv().await {
        assert!(event.seq > last_seq, "events are ordered by seq");
        last_seq = event.seq;
        let terminal = matches!(
            event.kind,
            JobEventKind::Done | JobEventKind::Failed { .. } | JobEventKind::Cancelled
        );
        events.push(event.kind);
        if terminal {
            break;
        }
    }
    events
}

fn local(path: &Path) -> Endpoint {
    Endpoint::Local(LocalRoot { base: path.to_owned(), rights: Rights::ReadWrite })
}

fn tree(path: &Path) {
    std::fs::create_dir_all(path.join("project/src")).unwrap();
    std::fs::write(path.join("project/readme.md"), "hello").unwrap();
    let big: Vec<u8> = (0..3_000_000_u32).map(|value| (value % 253) as u8).collect();
    std::fs::write(path.join("project/src/big.bin"), big).unwrap();
}

#[tokio::test]
async fn copies_a_tree_to_and_from_an_sftp_host() {
    let Some(binary) = sftp_server() else { return };
    let local_dir = tempfile::tempdir().unwrap();
    let remote_home = tempfile::tempdir().unwrap();
    tree(local_dir.path());
    let server = LocalServer::start(&binary, remote_home.path()).await;
    let remote = SftpRoot::open(
        server.client.clone(),
        remote_home.path().to_str().unwrap(),
        Rights::ReadWrite,
    )
    .await
    .unwrap();

    let mut upload = start_copy(CopyRequest {
        from: local(local_dir.path()),
        paths: vec!["project".into()],
        to: Endpoint::Sftp(remote.clone()),
        destination: String::new(),
        conflict: ConflictPolicy::Ask,
        window_bytes: 256 * 1024,
    });
    let events = finish(&mut upload).await;
    assert_eq!(events.last(), Some(&JobEventKind::Done), "{events:?}");
    assert!(
        matches!(events[0], JobEventKind::Preparing { items_total: 4, bytes_total: 3_000_005 }),
        "{events:?}"
    );
    assert_eq!(
        std::fs::read(remote_home.path().join("project/src/big.bin")).unwrap(),
        std::fs::read(local_dir.path().join("project/src/big.bin")).unwrap()
    );

    let back = tempfile::tempdir().unwrap();
    let mut download = start_copy(CopyRequest {
        from: Endpoint::Sftp(remote.clone()),
        paths: vec!["project/src/big.bin".into(), "project/readme.md".into()],
        to: local(back.path()),
        destination: String::new(),
        conflict: ConflictPolicy::Ask,
        window_bytes: bulk::DEFAULT_WINDOW_BYTES,
    });
    assert_eq!(finish(&mut download).await.last(), Some(&JobEventKind::Done));
    assert_eq!(std::fs::read_to_string(back.path().join("readme.md")).unwrap(), "hello");
    assert_eq!(std::fs::metadata(back.path().join("big.bin")).unwrap().len(), 3_000_000);
}

#[tokio::test]
async fn conflicts_ask_then_keep_both_or_replace() {
    let Some(binary) = sftp_server() else { return };
    let local_dir = tempfile::tempdir().unwrap();
    let remote_home = tempfile::tempdir().unwrap();
    std::fs::write(local_dir.path().join("note.txt"), "new").unwrap();
    std::fs::write(remote_home.path().join("note.txt"), "old").unwrap();
    let server = LocalServer::start(&binary, remote_home.path()).await;
    let remote = SftpRoot::open(
        server.client.clone(),
        remote_home.path().to_str().unwrap(),
        Rights::ReadWrite,
    )
    .await
    .unwrap();
    let request = |conflict| CopyRequest {
        from: local(local_dir.path()),
        paths: vec!["note.txt".into()],
        to: Endpoint::Sftp(remote.clone()),
        destination: String::new(),
        conflict,
        window_bytes: 1024,
    };

    let mut job = start_copy(request(ConflictPolicy::Ask));
    loop {
        let event = job.events.recv().await.unwrap();
        if let JobEventKind::Conflict { item, existing, incoming } = event.kind {
            assert_eq!(item, "note.txt");
            assert_eq!((existing.size, incoming.size), (3, 3));
            break;
        }
    }
    assert!(job.resolve(Choice::KeepBoth, false).await);
    assert_eq!(finish(&mut job).await.last(), Some(&JobEventKind::Done));
    assert_eq!(std::fs::read_to_string(remote_home.path().join("note.txt")).unwrap(), "old");
    assert_eq!(std::fs::read_to_string(remote_home.path().join("note 2.txt")).unwrap(), "new");

    let mut job = start_copy(request(ConflictPolicy::Replace));
    assert_eq!(finish(&mut job).await.last(), Some(&JobEventKind::Done));
    assert_eq!(std::fs::read_to_string(remote_home.path().join("note.txt")).unwrap(), "new");

    let mut job = start_copy(request(ConflictPolicy::Skip));
    assert_eq!(finish(&mut job).await.last(), Some(&JobEventKind::Done));
}

#[tokio::test]
async fn cancel_stops_the_transfer_and_removes_the_partial_file() {
    let Some(binary) = sftp_server() else { return };
    let local_dir = tempfile::tempdir().unwrap();
    let remote_home = tempfile::tempdir().unwrap();
    let big: Vec<u8> = vec![7; 64 * 1024 * 1024];
    std::fs::write(local_dir.path().join("huge.bin"), &big).unwrap();
    let server = LocalServer::start(&binary, remote_home.path()).await;
    let remote = SftpRoot::open(
        server.client.clone(),
        remote_home.path().to_str().unwrap(),
        Rights::ReadWrite,
    )
    .await
    .unwrap();
    let mut job = start_copy(CopyRequest {
        from: local(local_dir.path()),
        paths: vec!["huge.bin".into()],
        to: Endpoint::Sftp(remote),
        destination: String::new(),
        conflict: ConflictPolicy::Ask,
        window_bytes: 1024 * 1024,
    });
    loop {
        let event = job.events.recv().await.unwrap();
        if let JobEventKind::Progress { bytes_done, .. } = event.kind
            && bytes_done > 0
        {
            break;
        }
        assert!(!matches!(event.kind, JobEventKind::Done), "the copy finished before the cancel");
    }
    job.cancel();
    let events = finish(&mut job).await;
    assert_eq!(events.last(), Some(&JobEventKind::Cancelled), "{events:?}");
    assert!(events.contains(&JobEventKind::Cancelling));
    let remaining: Vec<_> = std::fs::read_dir(remote_home.path())
        .unwrap()
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .collect();
    assert!(remaining.is_empty(), "no partial or final file remains: {remaining:?}");
}

#[test]
fn join_handles_empty_and_nested_folders() {
    assert_eq!(join("", "a.txt"), "a.txt");
    assert_eq!(join("dir/", "a.txt"), "dir/a.txt");
}
