//! `cloud.file.push` and `cloud.file.pull` through the machine's daemon on
//! the link (behind `fs-v1`). No network: the transfer is a fake, or the
//! real one against fake daemon file ops.

mod attach_common;
mod common;
mod edge_common;

use cmux_cloud::{Origin, Request};
use edge_common::rig;
use serde_json::json;
use std::path::{Path, PathBuf};

const FIXTURES: &[&str] = &["vm-get", "connect-info-fs"];

fn scratch_file(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-cloud-test-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("upload.txt");
    std::fs::write(&file, b"payload").unwrap();
    file
}

fn push(local: &Path, key: &str) -> Request {
    Request::new(
        "cloud.file.push",
        json!({"machine": "vm-alpha01", "localPath": local, "path": "/home/cmux/upload.txt"}),
    )
    .key(key)
    .origin(Origin::User)
}

#[test]
fn a_failed_transfer_is_a_typed_error_and_the_job_names_the_host() {
    let local = scratch_file("fail");
    let mut rig = rig(FIXTURES);
    rig.transfer.log().fail_with = Some("the daemon link closed".into());
    let started = rig.server.handle(&push(&local, "p-1")).expect("the transfer starts");
    rig.server.wait_transfers();
    let ended = rig.server.take_transfer_events();
    assert_eq!(ended.len(), 1);
    assert_eq!(ended[0].transfer, started["transfer"].as_str().unwrap());
    assert_eq!(ended[0].outcome.as_ref().map_err(|e| e.code), Err("cmux.cloud.transfer_failed"));
    let job = rig.transfer.log().jobs.last().cloned().expect("a job");
    assert_eq!(job.target.host, "host-vm-alpha01", "the job dials the machine's host id");
    assert_eq!(job.target.binary.to_str(), Some("/opt/cmux/bin/cmux-tui"));
}

#[test]
fn local_paths_are_checked_and_pull_never_overwrites() {
    let local = scratch_file("local");
    let mut rig = rig(FIXTURES);
    let pull = |path: &str| {
        Request::new(
            "cloud.file.pull",
            json!({"machine": "vm-alpha01", "localPath": path, "path": "/home/cmux/notes.txt"}),
        )
        .key(&format!("l-{path:?}"))
        .origin(Origin::User)
    };
    let err = rig.server.handle(&pull(local.to_str().unwrap())).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.local_exists");
    for bad in ["relative.txt", "/tmp/../etc/passwd", "/tmp/a\0b", "/tmp/dir/"] {
        assert_eq!(
            rig.server.handle(&pull(bad)).unwrap_err().code,
            "cmux.cloud.invalid_args",
            "{bad:?}"
        );
    }
    let glob = Request::new(
        "cloud.file.push",
        json!({"machine": "vm-alpha01", "localPath": local, "path": "/home/cmux/*.txt"}),
    )
    .key("g-1")
    .origin(Origin::User);
    assert_eq!(rig.server.handle(&glob).unwrap_err().code, "cmux.cloud.invalid_args");
    assert!(rig.transfer.log().jobs.is_empty());
    assert!(rig.server.control_plane().no_calls(), "refused before any backend call");
}

#[test]
fn only_a_person_may_transfer_because_the_local_path_reaches_any_file() {
    let local = scratch_file("origin");
    let mut rig = rig(FIXTURES);
    for origin in [Origin::Cli, Origin::Mcp, Origin::Agent, Origin::Script, Origin::Remote] {
        let err = rig.server.handle(&push(&local, "o-1").origin(origin)).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.origin_refused", "{origin:?}");
        let pull = Request::new(
            "cloud.file.pull",
            json!({"machine": "vm-alpha01", "localPath": "/tmp/new.txt", "path": "/home/cmux/a"}),
        )
        .key("o-2")
        .origin(origin);
        assert_eq!(rig.server.handle(&pull).unwrap_err().code, "cmux.cloud.origin_refused");
    }
    assert!(rig.server.control_plane().no_calls());
}

#[test]
fn a_pull_lands_in_a_hidden_name_and_is_published_without_overwrite() {
    let dir = scratch_file("pull").parent().unwrap().to_path_buf();
    let target = dir.join("pulled.txt");
    let _ = std::fs::remove_file(&target);
    let mut rig = rig(FIXTURES);
    let pull = |key: &str| {
        Request::new(
            "cloud.file.pull",
            json!({"machine": "vm-alpha01", "localPath": target, "path": "/home/cmux/notes.txt"}),
        )
        .key(key)
        .origin(Origin::User)
    };
    let leftovers = |dir: &Path| {
        std::fs::read_dir(dir)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().contains("cmux-pull"))
            .count()
    };
    rig.transfer.log().fail_with = Some("the daemon link closed".into());
    rig.server.handle(&pull("u-1")).expect("the pull starts");
    rig.server.wait_transfers();
    let failed = rig.server.take_transfer_events();
    assert_eq!(failed[0].outcome.as_ref().map_err(|e| e.code), Err("cmux.cloud.transfer_failed"));
    assert!(!target.exists() && leftovers(&dir) == 0, "a failed pull leaves nothing");
    rig.server.handle(&pull("u-2")).expect("the retry runs");
    rig.server.wait_transfers();
    assert_eq!(rig.server.take_transfer_events()[0].outcome, Ok(42));
    assert_eq!(std::fs::read(&target).unwrap(), b"pulled");
    assert_eq!(leftovers(&dir), 0);
    let landed = rig.transfer.log().jobs.last().unwrap().local.clone();
    assert_ne!(landed, target, "a pull never writes the target name itself");
    assert_eq!(landed.parent(), target.parent());
    let _ = std::fs::remove_file(&target);
}

/// The real daemon transfer against the fake daemon files: a pull reads
/// ranges until the answer is not truncated; a push is one create write.
#[test]
fn the_daemon_transfer_pulls_in_ranges_and_pushes_with_create() {
    use cmux_cloud::fs::{Cancel, DaemonTransfer, DialTarget, Direction, Transfer, TransferJob};
    use std::sync::Arc;
    let files = edge_common::FakeFiles::default();
    let transfer = DaemonTransfer::new(Arc::new(files.clone()));
    let target = DialTarget {
        binary: PathBuf::from("/opt/cmux/bin/cmux"),
        host: "host-vm-alpha01".into(),
        env: Vec::new(),
    };
    let dir = scratch_file("daemon").parent().unwrap().to_path_buf();
    let landing = dir.join(".pulled.cmux-pull-test");
    let _ = std::fs::remove_file(&landing);
    files.answer(
        "fs.read",
        json!({ "text": "abc", "truncated": false, "size": 3,
        "encoding": "utf-8" }),
    );
    let pull = TransferJob {
        machine: "vm-alpha01".into(),
        direction: Direction::Pull,
        local: landing.clone(),
        guest: "/home/cmux/a.txt".into(),
        target,
    };
    assert_eq!(transfer.run(&pull, &Cancel::default()), Ok(3));
    assert_eq!(std::fs::read(&landing).unwrap(), b"abc");
    let (_, op, params) = files.log().calls[0].clone();
    assert_eq!(op, "fs.read");
    assert_eq!(params, json!({ "path": "/home/cmux/a.txt", "offset": 0, "max_bytes": 1048576 }));
    let cancel = Cancel::default();
    cancel.cancel();
    let _ = std::fs::remove_file(&landing);
    assert!(transfer.run(&pull, &cancel).is_err(), "a cancelled pull stops before a read");
    let push = TransferJob {
        direction: Direction::Push,
        local: scratch_file("daemon-push"),
        guest: "/home/cmux/upload.txt".into(),
        ..pull
    };
    assert_eq!(transfer.run(&push, &Cancel::default()), Ok(7));
    let (_, op, params) = files.log().calls.last().cloned().unwrap();
    assert_eq!(op, "fs.write");
    assert_eq!(params["mode"], "create", "a push never overwrites");
    assert_eq!(params["bytes_base64"], "cGF5bG9hZA==");
    let _ = std::fs::remove_file(&landing);
}

/// A push above one daemon write (12 MiB raw, decision D2) is refused before
/// any backend call, with a reason that names the missing write stream.
#[test]
fn a_push_above_twelve_mib_needs_the_write_stream() {
    let dir = scratch_file("big").parent().unwrap().to_path_buf();
    let big = dir.join("big.bin");
    std::fs::write(&big, vec![0u8; 12 * 1024 * 1024 + 1]).unwrap();
    let mut rig = rig(FIXTURES);
    let err = rig.server.handle(&push(&big, "b-1")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.file_too_large");
    assert!(err.message.contains("write stream"), "{}", err.message);
    assert!(rig.server.control_plane().no_calls());
    let _ = std::fs::remove_file(&big);
}
