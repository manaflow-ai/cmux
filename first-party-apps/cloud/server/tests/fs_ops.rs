//! `cloud.fs.*` and `cmux.fs.provider/1` on the machine's daemon (fake
//! daemon file ops behind the `fs-v1` gate).

mod attach_common;
mod common;
mod edge_common;

use cmux_cloud::fs::{FsProvider, GuestPath, MAX_READ_BYTES, Root};
use cmux_cloud::{Origin, Request};
use edge_common::rig;
use serde_json::json;

const FILES: &[&str] = &["vm-get", "connect-info-fs"];

fn op(name: &str, args: serde_json::Value) -> Request {
    Request::new(name, args)
}

#[test]
fn guest_paths_refuse_dotdot_relative_nul_and_long() {
    for bad in
        ["", "home/cmux", "./x", "/home/../etc", "/a/..", "/a\0b", "/a\nb", "..", "/x/../../y"]
    {
        assert!(GuestPath::parse(bad).is_err(), "{bad:?} must be refused");
    }
    assert!(GuestPath::parse(&format!("/{}", "a".repeat(4096))).is_err(), "over 4096 bytes");
    for good in ["/", "/home/cmux", "/home/cmux/a..b", "/srv/.hidden", "/a b/c"] {
        assert!(GuestPath::parse(good).is_ok(), "{good:?} is fine");
    }
    assert!(GuestPath::parse("/home/cmux/a b&c=d?e#f%").is_ok(), "any literal name is fine");
}

#[test]
fn bad_paths_never_reach_the_backend_or_the_daemon() {
    let mut rig = rig(FILES);
    for bad in ["relative/x", "/home/../etc/passwd", "/a\u{0}b"] {
        for name in ["cloud.fs.list", "cloud.fs.stat", "cloud.fs.read"] {
            let err = rig
                .server
                .handle(&op(name, json!({"machine": "vm-alpha01", "path": bad})))
                .unwrap_err();
            assert_eq!(err.code, "cmux.cloud.invalid_args", "{name} {bad:?}");
        }
    }
    assert!(rig.server.control_plane().no_calls(), "no call left this machine");
    assert!(rig.files.ops().is_empty(), "no daemon op");
}

fn stat_answer(size: u64) -> serde_json::Value {
    json!({ "name": "notes.txt", "kind": "file", "size": size, "mtime": 1.0e12,
        "revision": "s12-m1", "mode_display": "rw-r--r--", "owner_display": "cmux" })
}

fn files_rig() -> edge_common::Rig {
    let rig = rig(FILES);
    rig.files.answer(
        "fs.list",
        json!({ "entries": [
            { "name": "a.txt", "kind": "file", "size": 3, "mtime": 1.0e12 },
            { "name": "src", "kind": "dir", "size": null, "mtime": 1.0e12 },
            { "name": "link", "kind": "symlink", "size": null, "mtime": null } ],
            "listing": "lst_1", "total": 3, "revision": "r1" }),
    );
    rig.files.answer("fs.stat", stat_answer(12));
    rig.files.answer(
        "fs.read",
        json!({ "text": "hello cloud\n", "truncated": false, "size": 12, "encoding": "utf-8" }),
    );
    rig.files.answer(
        "fs.write",
        json!({ "entry": { "name": "notes.txt", "kind": "file",
        "size": 12, "revision": "s12-m2" } }),
    );
    rig.files.answer("fs.mkdir", json!({ "entry": { "name": "new", "kind": "dir" } }));
    rig.files.answer("fs.delete", json!({}));
    rig
}

#[test]
fn list_stat_and_read_map_the_daemon_answers() {
    let mut rig = files_rig();
    let list = rig
        .server
        .handle(&op("cloud.fs.list", json!({"machine": "vm-alpha01", "path": "/home/cmux"})))
        .unwrap();
    let kinds: Vec<&str> =
        list["entries"].as_array().unwrap().iter().map(|e| e["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["file", "directory", "symlink"], "dir becomes directory");
    let stat = rig
        .server
        .handle(&op(
            "cloud.fs.stat",
            json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt"}),
        ))
        .unwrap();
    assert_eq!(stat["path"], "/home/cmux/notes.txt");
    assert_eq!(stat["size"], 12);
    let read = rig
        .server
        .handle(&op(
            "cloud.fs.read",
            json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt"}),
        ))
        .unwrap();
    assert_eq!(read["dataBase64"], "aGVsbG8gY2xvdWQK");
    assert_eq!(rig.files.ops(), ["fs.list", "fs.stat", "fs.stat", "fs.read"]);
    let log = rig.files.log();
    let (target, _, params) = &log.calls[0];
    assert_eq!(target.host, "host-vm-alpha01");
    assert_eq!(params["path"], "/home/cmux");
    assert_eq!(params["filter"], json!({ "hidden": true }), "the explorer shows dotfiles (D5c)");
    assert_eq!(
        log.calls[3].2,
        json!({"path": "/home/cmux/notes.txt", "offset": 0, "max_bytes": 1048576}),
        "reads go in 1 MiB ranges (the daemon's cap)"
    );
    drop(log);
    assert_eq!(
        rig.server.control_plane().ops().iter().filter(|o| o.ends_with("connect_info")).count(),
        1,
        "the capability gate is one cached read (no token) for all four ops"
    );
}

#[test]
fn a_read_above_the_bound_is_a_typed_error_before_any_byte_moves() {
    let mut rig = files_rig();
    rig.files.answer("fs.stat", stat_answer(MAX_READ_BYTES as u64 + 1));
    let err = rig
        .server
        .handle(&op(
            "cloud.fs.read",
            json!({"machine": "vm-alpha01", "path": "/home/cmux/big.bin"}),
        ))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.file_too_large");
    assert_eq!(rig.files.ops(), ["fs.stat"], "no fs.read");
    rig.files.answer("fs.stat", stat_answer(12));
    // The file grew past the bound after the stat: every 1 MiB range says
    // "more", so the read stops at the bound and refuses.
    rig.files.answer(
        "fs.read",
        json!({ "text": "x".repeat(1 << 20), "truncated": true, "size": 99_999_999,
            "encoding": "utf-8" }),
    );
    let err = rig
        .server
        .handle(&op("cloud.fs.read", json!({"machine": "vm-alpha01", "path": "/home/cmux/grew"})))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.file_too_large", "a file that grew is refused too");
    // A daemon that says "more" with a tiny answer is a protocol break.
    rig.files.answer(
        "fs.read",
        json!({ "text": "x", "truncated": true, "size": 99,
        "encoding": "utf-8" }),
    );
    let err = rig
        .server
        .handle(&op("cloud.fs.read", json!({"machine": "vm-alpha01", "path": "/home/cmux/slow"})))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.bad_response");
}

#[test]
fn write_sends_base64_overwrite_or_replace_and_a_retry_does_not_write_twice() {
    let mut rig = files_rig();
    let write = op(
        "cloud.fs.write",
        json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt",
        "dataBase64": "aGVsbG8gY2xvdWQK"}),
    )
    .key("w-1");
    let first = rig.server.handle(&write).unwrap();
    assert_eq!(
        first,
        json!({"ok": true, "path": "/home/cmux/notes.txt", "size": 12,
        "revision": "s12-m2"})
    );
    assert_eq!(rig.server.handle(&write).unwrap(), first);
    assert_eq!(rig.files.ops(), ["fs.write"], "a same-key retry makes no second write");
    assert_eq!(
        rig.files.log().calls[0].2,
        json!({"path": "/home/cmux/notes.txt",
        "bytes_base64": "aGVsbG8gY2xvdWQK", "mode": "overwrite"})
    );
    let based = op(
        "cloud.fs.write",
        json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt",
        "dataBase64": "aGk=", "baseRevision": "s12-m1"}),
    )
    .key("w-2");
    rig.server.handle(&based).unwrap();
    let params = rig.files.log().calls[1].2.clone();
    assert_eq!(
        (params["mode"].as_str(), params["expected"].as_str()),
        (Some("replace"), Some("s12-m1"))
    );
    let unkeyed =
        op("cloud.fs.write", json!({"machine": "vm-alpha01", "path": "/x", "dataBase64": ""}));
    assert_eq!(
        rig.server.handle(&unkeyed).unwrap_err().code,
        "cmux.cloud.idempotency_key_required"
    );
}

#[test]
fn write_refuses_a_file_mode_bad_base64_and_too_much_data() {
    let mut rig = files_rig();
    let write = |extra: serde_json::Value, key: &str| {
        let mut args = json!({"machine": "vm-alpha01", "path": "/home/cmux/n.txt"});
        args.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        op("cloud.fs.write", args).key(key)
    };
    let err =
        rig.server.handle(&write(json!({"dataBase64": "aGk=", "mode": 420}), "a")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.unsupported", "the daemon write sets no mode");
    let err = rig.server.handle(&write(json!({"dataBase64": "%%%"}), "b")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.invalid_args");
    // One daemon fs.write is at most 12 MiB raw (decision D2).
    let over = "A".repeat((12 * 1024 * 1024 / 3 + 2) * 4);
    let err = rig.server.handle(&write(json!({"dataBase64": over}), "d")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.file_too_large", "12 MiB is the bound");
    let big = "A".repeat((MAX_READ_BYTES / 3 + 2) * 4 + 8);
    let err = rig.server.handle(&write(json!({"dataBase64": big}), "c")).unwrap_err();
    assert_eq!(err.code, "cmux.cloud.file_too_large");
    assert!(rig.files.ops().is_empty(), "nothing reached the daemon");
}

#[test]
fn daemon_errors_are_typed_and_keep_the_daemon_code() {
    let mut rig = files_rig();
    rig.files.log().errors.insert("fs.stat".into(), "fs.not_found".into());
    let err = rig
        .server
        .handle(&op("cloud.fs.stat", json!({"machine": "vm-alpha01", "path": "/nope"})))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.not_found");
    assert_eq!(err.upstream_code.as_deref(), Some("fs.not_found"));
}

#[test]
fn mkdir_and_remove_map_to_the_daemon_ops_and_remove_needs_a_person() {
    let mut rig = files_rig();
    rig.server
        .handle(
            &op("cloud.fs.mkdir", json!({"machine": "vm-alpha01", "path": "/home/cmux/new"}))
                .key("m-1"),
        )
        .unwrap();
    assert_eq!(rig.files.log().calls[0].2, json!({"path": "/home/cmux", "name": "new"}));
    let remove =
        op("cloud.fs.remove", json!({"machine": "vm-alpha01", "path": "/home/cmux/old.txt"}))
            .key("r-1");
    for origin in [Origin::Cli, Origin::Mcp, Origin::Agent, Origin::Script] {
        let err = rig.server.handle(&remove.clone().origin(origin)).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.origin_refused", "{origin:?}");
    }
    rig.server.handle(&remove.origin(Origin::User)).unwrap();
    assert_eq!(
        rig.files.log().calls[1].2,
        json!({"paths": ["/home/cmux/old.txt"],
        "permanent": true})
    );
}

#[test]
fn the_fs_provider_view_serves_cloud_vm_roots_only() {
    let mut rig = files_rig();
    assert!(Root::new("ssh", "vm-alpha01").is_err());
    assert!(Root::new("cloud-vm", "../x").is_err());
    let root = Root::new("cloud-vm", "vm-alpha01").unwrap();
    let mut fs = rig.server.fs_provider();
    assert_eq!(fs.schemes(), &["cloud-vm"]);
    assert_eq!(fs.list(&root, "/home/cmux", None).unwrap().len(), 3);
    assert_eq!(fs.read(&root, "/home/cmux/notes.txt", None).unwrap(), b"hello cloud\n");
    assert_eq!(fs.read(&root, "/home/cmux/notes.txt", Some((0, 64))).unwrap(), b"hello cloud\n");
    assert_eq!(
        fs.read(&root, "/home/cmux/notes.txt", Some((0, 4))).unwrap_err().code,
        "cmux.cloud.bad_response",
        "an answer longer than the range asked is a protocol break"
    );
    assert_eq!(fs.stat(&root, "/home/cmux/notes.txt").unwrap().size, Some(12));
    assert_eq!(
        fs.write(&root, "/home/cmux/notes.txt", b"hi", Some("s12-m1")).unwrap(),
        Some("s12-m2".into())
    );
    assert_eq!(fs.list(&root, "/home/cmux", Some("c")).unwrap_err().code, "cmux.cloud.unsupported");
    assert_eq!(fs.stat(&root, "/home/../etc").unwrap_err().code, "cmux.cloud.invalid_args");
}
