//! `cloud.fs.*` and `cmux.fs.provider/1` against recorded Cloud API answers.

mod attach_common;
mod common;
mod edge_common;

use cmux_cloud::fs::{FsProvider, GuestPath, MAX_READ_BYTES, Root};
use cmux_cloud::{Origin, Request};
use edge_common::rig;
use serde_json::json;

const FILES: &[&str] =
    &["fs-dir", "fs-stat", "fs-read", "fs-stat-large", "fs-write", "fs-mkdir", "fs-remove"];

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
    let path = GuestPath::parse("/home/cmux/a b&c=d?e#f%").unwrap();
    assert_eq!(
        path.query_value(),
        "/home/cmux/a%20b%26c%3Dd%3Fe%23f%25",
        "no path adds a query field"
    );
}

#[test]
fn bad_paths_never_reach_the_cloud_api() {
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
}

#[test]
fn list_stat_and_read_map_the_recorded_answers() {
    let mut rig = rig(FILES);
    let listing = rig
        .server
        .handle(&op("cloud.fs.list", json!({"machine": "vm-alpha01", "path": "/home/cmux"})))
        .unwrap();
    assert_eq!(listing["path"], "/home/cmux");
    let names: Vec<_> =
        listing["entries"].as_array().unwrap().iter().map(|e| e["name"].clone()).collect();
    assert_eq!(names, [json!("notes.txt"), json!("src"), json!("latest")]);
    assert_eq!(listing["entries"][1]["kind"], "directory");
    assert_eq!(listing["entries"][0]["size"], 12);

    let stat = rig
        .server
        .handle(&op(
            "cloud.fs.stat",
            json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt"}),
        ))
        .unwrap();
    assert_eq!(stat["kind"], "file");
    assert_eq!(stat["mode"], 420);
    assert_eq!(stat["modifiedAt"], 1_791_100_000_000_f64);

    let read = rig
        .server
        .handle(&op(
            "cloud.fs.read",
            json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt"}),
        ))
        .unwrap();
    assert_eq!(read["dataBase64"], "aGVsbG8gY2xvdWQK");
    assert_eq!(read["size"], 12);
    let calls: Vec<String> = rig
        .server
        .control_plane()
        .calls
        .iter()
        .map(|c| format!("{} {}", c.method, c.path))
        .collect();
    assert!(
        calls.contains(&"GET /api/vm/vm-alpha01/fs/stat?path=/home/cmux/notes.txt".to_owned()),
        "stat before read: {calls:?}"
    );
    assert!(calls.iter().all(|c| c.starts_with("GET ")), "reads only");
}

#[test]
fn a_read_above_the_bound_is_a_typed_error_before_any_byte_moves() {
    let mut rig = rig(FILES);
    let err = rig
        .server
        .handle(&op(
            "cloud.fs.read",
            json!({"machine": "vm-alpha01", "path": "/home/cmux/big.bin"}),
        ))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.file_too_large");
    assert!(err.message.contains(&MAX_READ_BYTES.to_string()), "{}", err.message);
    assert_eq!(
        rig.server
            .control_plane()
            .count("GET", "/api/vm/vm-alpha01/fs/read?path=/home/cmux/big.bin"),
        0
    );
}

#[test]
fn a_read_answer_above_the_bound_is_refused_too() {
    let mut rig = rig(FILES);
    // The stat said small, the file grew before the read.
    let big = "A".repeat((MAX_READ_BYTES / 3 + 4) * 4);
    rig.server.control_plane_mut().respond(
        "GET",
        "/api/vm/vm-alpha01/fs/read?path=/home/cmux/notes.txt",
        200,
        json!({"path": "/home/cmux/notes.txt", "dataBase64": big}),
    );
    let err = rig
        .server
        .handle(&op(
            "cloud.fs.read",
            json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt"}),
        ))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.file_too_large");
}

#[test]
fn write_sends_base64_with_a_key_and_a_retry_does_not_write_twice() {
    let mut rig = rig(FILES);
    let write = op(
        "cloud.fs.write",
        json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt",
        "dataBase64": "aGVsbG8gY2xvdWQK", "mode": 420}),
    )
    .key("w-1");
    let first = rig.server.handle(&write).unwrap();
    assert_eq!(first, json!({"ok": true, "path": "/home/cmux/notes.txt", "size": 12}));
    let again = rig.server.handle(&write).unwrap();
    assert_eq!(first, again);
    let calls = &rig.server.control_plane().calls;
    assert_eq!(calls.len(), 1, "a same-key retry makes no second write");
    assert_eq!(calls[0].body.as_ref().unwrap()["dataBase64"], "aGVsbG8gY2xvdWQK");
    assert_eq!(calls[0].body.as_ref().unwrap()["mode"], 420);
    assert!(calls[0].idempotency_key.is_some());
    let unkeyed =
        op("cloud.fs.write", json!({"machine": "vm-alpha01", "path": "/x", "dataBase64": ""}));
    assert_eq!(
        rig.server.handle(&unkeyed).unwrap_err().code,
        "cmux.cloud.idempotency_key_required"
    );
}

#[test]
fn write_refuses_a_base_revision_bad_base64_and_too_much_data() {
    let mut rig = rig(FILES);
    let args = |extra: serde_json::Value| {
        let mut a =
            json!({"machine": "vm-alpha01", "path": "/home/cmux/notes.txt", "dataBase64": "aGk="});
        a.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        a
    };
    let err = rig
        .server
        .handle(&op("cloud.fs.write", args(json!({"baseRevision": "r1"}))).key("w-1"))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.unsupported", "no silent loss of the conflict check");
    let err = rig
        .server
        .handle(&op("cloud.fs.write", args(json!({"dataBase64": "not base64!"}))).key("w-2"))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.invalid_args");
    let huge = "A".repeat((16 * 1024 * 1024 / 3 + 8) * 4);
    let err = rig
        .server
        .handle(&op("cloud.fs.write", args(json!({"dataBase64": huge}))).key("w-3"))
        .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.file_too_large");
    assert!(rig.server.control_plane().no_calls());
}

#[test]
fn mkdir_and_remove_use_their_routes_and_remove_needs_a_person() {
    let mut rig = rig(FILES);
    rig.server
        .handle(
            &op("cloud.fs.mkdir", json!({"machine": "vm-alpha01", "path": "/home/cmux/new"}))
                .key("m-1"),
        )
        .unwrap();
    assert_eq!(rig.server.control_plane().calls[0].body, Some(json!({"path": "/home/cmux/new"})));
    let remove =
        op("cloud.fs.remove", json!({"machine": "vm-alpha01", "path": "/home/cmux/old.txt"}))
            .key("r-1");
    for origin in [Origin::Cli, Origin::Mcp, Origin::Agent, Origin::Script] {
        let err = rig.server.handle(&remove.clone().origin(origin)).unwrap_err();
        assert_eq!(err.code, "cmux.cloud.origin_refused", "{origin:?}");
    }
    rig.server.handle(&remove.origin(Origin::User)).unwrap();
    assert_eq!(
        rig.server
            .control_plane()
            .count("DELETE", "/api/vm/vm-alpha01/fs/remove?path=/home/cmux/old.txt"),
        1
    );
}

#[test]
fn the_fs_provider_view_serves_cloud_vm_roots_only() {
    let mut rig = rig(FILES);
    assert!(Root::new("ssh", "vm-alpha01").is_err());
    assert!(Root::new("cloud-vm", "../x").is_err());
    let root = Root::new("cloud-vm", "vm-alpha01").unwrap();
    let mut fs = rig.server.fs_provider();
    assert_eq!(fs.schemes(), &["cloud-vm"]);
    assert_eq!(fs.list(&root, "/home/cmux", None).unwrap().len(), 3);
    assert_eq!(fs.read(&root, "/home/cmux/notes.txt", None).unwrap(), b"hello cloud\n");
    assert_eq!(fs.stat(&root, "/home/cmux/notes.txt").unwrap().size, Some(12));
    assert_eq!(fs.write(&root, "/home/cmux/notes.txt", b"hi", None).unwrap(), None);
    assert_eq!(
        fs.write(&root, "/home/cmux/notes.txt", b"hi", Some("r1")).unwrap_err().code,
        "cmux.cloud.unsupported"
    );
    assert_eq!(
        fs.read(&root, "/home/cmux/notes.txt", Some((0, 4))).unwrap_err().code,
        "cmux.cloud.unsupported"
    );
    assert_eq!(fs.list(&root, "/home/cmux", Some("c")).unwrap_err().code, "cmux.cloud.unsupported");
    assert_eq!(fs.stat(&root, "/home/../etc").unwrap_err().code, "cmux.cloud.invalid_args");
    assert!(fs.read(&root, "/home/cmux/big.bin", None).is_err());
}
