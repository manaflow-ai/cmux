//! Behavior of the `fs-v1` ops on a temporary root.

use std::fs;
use std::io::Cursor;
use std::os::unix::fs::{PermissionsExt as _, symlink};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::stream::{self, StreamRequest};
use super::*;

/// A temporary root, removed on drop.
pub(super) struct TempRoot {
    pub path: PathBuf,
}

impl TempRoot {
    pub fn new(label: &str) -> Self {
        let base = std::env::temp_dir().join(format!(
            "cmux-fs-{label}-{}-{}",
            std::process::id(),
            sys::random_hex(6)
        ));
        fs::create_dir_all(&base).unwrap();
        Self { path: fs::canonicalize(&base).unwrap() }
    }

    /// The absolute request path of `relative` under the root.
    pub fn at(&self, relative: &str) -> String {
        if relative.is_empty() {
            return self.path.display().to_string();
        }
        format!("{}/{relative}", self.path.display())
    }

    pub fn service(&self) -> FsService {
        FsService::new(Roots::new([self.path.clone()]))
    }

    pub fn file(&self, relative: &str, contents: &[u8]) {
        let path = self.path.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn call(service: &FsService, cmd: &str, params: Value) -> Result<Value, FsError> {
    service.call("owner", cmd, params)
}

fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> =
        fs::read_dir(dir).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
    names.sort();
    names
}

#[test]
fn stat_answers_the_entry_revision_and_display_strings() {
    let root = TempRoot::new("stat");
    root.file("notes.txt", b"hello world\n");
    let data = call(&root.service(), "fs.stat", json!({ "path": root.at("notes.txt") })).unwrap();
    assert_eq!(data["name"], "notes.txt");
    assert_eq!(data["kind"], "file");
    assert_eq!(data["size"], 12);
    let mtime = data["mtime"].as_u64().unwrap();
    assert_eq!(data["revision"], format!("s12-m{mtime}"));
    assert_eq!(data["mode_display"].as_str().unwrap().len(), 9);
    assert!(!data["owner_display"].as_str().unwrap().is_empty());
    let dir = call(&root.service(), "fs.stat", json!({ "path": root.at("") })).unwrap();
    assert_eq!(dir["kind"], "dir");
    assert_eq!(dir["size"], Value::Null, "a folder has no size");
    assert_eq!(
        call(&root.service(), "fs.stat", json!({ "path": root.at("missing") })),
        Err(FsError::NotFound)
    );
}

#[test]
fn list_pages_a_sorted_snapshot_and_hides_dotfiles_by_default() {
    let root = TempRoot::new("list");
    for name in ["b.txt", "a10.txt", "a2.txt", ".hidden"] {
        root.file(name, b"x");
    }
    fs::create_dir(root.path.join("sub")).unwrap();
    let service = root.service();
    let first = call(&service, "fs.list", json!({ "path": root.at(""), "limit": 2 })).unwrap();
    let names: Vec<&str> =
        first["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["a2.txt", "a10.txt"], "natural order, dotfile hidden");
    assert_eq!(first["total"], 4);
    assert!(first["listing"].as_str().unwrap().starts_with("lst_"));
    let next = call(
        &service,
        "fs.list",
        json!({ "listing": first["listing"], "cursor": first["cursor"], "limit": 2 }),
    )
    .unwrap();
    assert_eq!(next["entries"][1]["name"], "sub");
    assert_eq!(next["entries"][1]["kind"], "dir");
    assert_eq!(next["cursor"], Value::Null);
    let all = call(
        &service,
        "fs.list",
        json!({ "path": root.at(""), "limit": 1000, "filter": { "hidden": true } }),
    )
    .unwrap();
    assert_eq!(all["total"], 5);
    assert_eq!(
        call(&service, "fs.list", json!({ "path": root.at("b.txt"), "limit": 10 })),
        Err(FsError::NotADirectory)
    );
    assert!(matches!(
        call(&service, "fs.list", json!({ "path": root.at(""), "limit": 0 })),
        Err(FsError::ParamsInvalid(_))
    ));
}

#[test]
fn read_returns_text_or_base64_and_marks_truncation() {
    let root = TempRoot::new("read");
    root.file("t.txt", b"hello\n");
    root.file("b.bin", &[0xff, 0x00, 0x01]);
    let service = root.service();
    let text =
        call(&service, "fs.read", json!({ "path": root.at("t.txt"), "offset": 0, "max_bytes": 3 }))
            .unwrap();
    assert_eq!(text, json!({ "text": "hel", "truncated": true, "size": 6, "encoding": "utf-8" }));
    let rest = call(
        &service,
        "fs.read",
        json!({ "path": root.at("t.txt"), "offset": 3, "max_bytes": 99 }),
    )
    .unwrap();
    assert_eq!(rest["text"], "lo\n");
    assert_eq!(rest["truncated"], false);
    let binary =
        call(&service, "fs.read", json!({ "path": root.at("b.bin"), "offset": 0, "max_bytes": 9 }))
            .unwrap();
    assert_eq!(binary["bytes_base64"], "/wAB");
    assert_eq!(binary["encoding"], "base64");
    assert!(binary.get("text").is_none(), "exactly one of text and bytes_base64");
    assert_eq!(
        call(&service, "fs.read", json!({ "path": root.at(""), "offset": 0, "max_bytes": 9 })),
        Err(FsError::NotAFile)
    );
}

#[test]
fn read_never_opens_a_fifo() {
    let root = TempRoot::new("fifo");
    let fifo = std::ffi::CString::new(root.path.join("pipe").display().to_string()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    assert_eq!(
        call(
            &root.service(),
            "fs.read",
            json!({ "path": root.at("pipe"), "offset": 0, "max_bytes": 9 })
        ),
        Err(FsError::NotAFile)
    );
}

#[test]
fn write_modes_create_overwrite_and_replace() {
    let root = TempRoot::new("write");
    let service = root.service();
    let path = root.at("a.txt");
    let created = call(
        &service,
        "fs.write",
        json!({ "path": path, "bytes_base64": "aGk=", "mode": "create" }),
    )
    .unwrap();
    assert_eq!(fs::read(root.path.join("a.txt")).unwrap(), b"hi");
    let revision = created["entry"]["revision"].as_str().unwrap().to_owned();
    assert!(revision.starts_with("s2-m"));
    assert_eq!(
        call(&service, "fs.write", json!({ "path": path, "text": "x", "mode": "create" })),
        Err(FsError::Exists)
    );
    let stale = json!({ "path": path, "text": "new", "mode": "replace", "expected": "s9-m1" });
    assert_eq!(
        call(&service, "fs.write", stale),
        Err(FsError::RevisionMismatch { current: Some(revision.clone()) })
    );
    call(
        &service,
        "fs.write",
        json!({ "path": path, "text": "new", "mode": "replace", "expected": revision }),
    )
    .unwrap();
    assert_eq!(fs::read(root.path.join("a.txt")).unwrap(), b"new");
    call(&service, "fs.write", json!({ "path": path, "text": "o", "mode": "overwrite" })).unwrap();
    assert_eq!(fs::read(root.path.join("a.txt")).unwrap(), b"o");
    assert_eq!(names_in(&root.path), ["a.txt"], "no temporary file is left behind");
}

#[test]
fn write_keeps_the_replaced_files_permissions() {
    let root = TempRoot::new("perm");
    root.file("run.sh", b"#!/bin/sh\n");
    fs::set_permissions(root.path.join("run.sh"), fs::Permissions::from_mode(0o750)).unwrap();
    call(
        &root.service(),
        "fs.write",
        json!({ "path": root.at("run.sh"), "text": "echo\n", "mode": "overwrite" }),
    )
    .unwrap();
    let mode = fs::metadata(root.path.join("run.sh")).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o750);
}

#[test]
fn write_refuses_bad_params_and_oversized_bodies() {
    let root = TempRoot::new("params");
    let service = root.service();
    let path = root.at("a.txt");
    for params in [
        json!({ "path": path, "mode": "create" }),
        json!({ "path": path, "text": "a", "bytes_base64": "YQ==", "mode": "create" }),
        json!({ "path": path, "text": "a", "mode": "append" }),
        json!({ "path": path, "text": "a", "mode": "replace" }),
        json!({ "path": path, "text": "a", "mode": "create", "expected": "s1-m1" }),
        json!({ "path": path, "bytes_base64": "%%%", "mode": "create" }),
        json!({ "path": "relative.txt", "text": "a", "mode": "create" }),
    ] {
        assert!(
            matches!(call(&service, "fs.write", params.clone()), Err(FsError::ParamsInvalid(_))),
            "{params}"
        );
    }
    let big = "a".repeat(MAX_WRITE_BYTES + 1);
    assert!(matches!(
        call(&service, "fs.write", json!({ "path": path, "text": big, "mode": "create" })),
        Err(FsError::TooLarge { .. })
    ));
    assert_eq!(names_in(&root.path), Vec::<String>::new());
}

#[test]
fn mkdir_rename_and_delete() {
    let root = TempRoot::new("tree");
    let service = root.service();
    let made = call(&service, "fs.mkdir", json!({ "path": root.at(""), "name": "new" })).unwrap();
    assert_eq!(made["entry"]["kind"], "dir");
    assert_eq!(
        call(&service, "fs.mkdir", json!({ "path": root.at(""), "name": "new" })),
        Err(FsError::Exists)
    );
    assert!(matches!(
        call(&service, "fs.mkdir", json!({ "path": root.at(""), "name": "a/b" })),
        Err(FsError::ParamsInvalid(_))
    ));
    root.file("new/deep/x.txt", b"x");
    root.file("other", b"y");
    assert_eq!(
        call(&service, "fs.rename", json!({ "path": root.at("other"), "name": "new" })),
        Err(FsError::Exists),
        "rename never replaces"
    );
    let renamed =
        call(&service, "fs.rename", json!({ "path": root.at("new"), "name": "old" })).unwrap();
    assert_eq!(renamed["entry"]["name"], "old");
    assert_eq!(
        call(&service, "fs.rename", json!({ "path": root.at("gone"), "name": "x" })),
        Err(FsError::NotFound)
    );
    assert!(matches!(
        call(&service, "fs.delete", json!({ "paths": [root.at("old")] })),
        Err(FsError::ParamsInvalid(_))
    ));
    call(&service, "fs.delete", json!({ "paths": [root.at("old")], "permanent": true })).unwrap();
    assert_eq!(names_in(&root.path), ["other"]);
    assert_eq!(
        call(&service, "fs.delete", json!({ "paths": [root.at("old")], "permanent": true })),
        Err(FsError::NotFound)
    );
}

#[test]
fn delete_removes_a_symlink_never_its_target() {
    let root = TempRoot::new("dellink");
    let outside = TempRoot::new("dellink-outside");
    outside.file("keep/precious.txt", b"keep");
    symlink(outside.path.join("keep"), root.path.join("link")).unwrap();
    fs::create_dir(root.path.join("dir")).unwrap();
    symlink(outside.path.join("keep"), root.path.join("dir/inner")).unwrap();
    let service = root.service();
    call(
        &service,
        "fs.delete",
        json!({ "paths": [root.at("link"), root.at("dir")], "permanent": true }),
    )
    .unwrap();
    assert_eq!(names_in(&root.path), Vec::<String>::new());
    assert_eq!(fs::read(outside.path.join("keep/precious.txt")).unwrap(), b"keep");
}

#[test]
fn a_root_cannot_be_renamed_deleted_or_overwritten() {
    let root = TempRoot::new("rootop");
    let service = root.service();
    assert_eq!(
        call(&service, "fs.delete", json!({ "paths": [root.at("")], "permanent": true })),
        Err(FsError::PermissionDenied)
    );
    assert_eq!(
        call(&service, "fs.rename", json!({ "path": root.at(""), "name": "x" })),
        Err(FsError::PermissionDenied)
    );
    assert_eq!(
        call(
            &service,
            "fs.write",
            json!({ "path": root.at(""), "text": "x", "mode": "overwrite" })
        ),
        Err(FsError::PermissionDenied)
    );
    assert!(root.path.is_dir());
}

fn stream_write(service: &FsService, line: &str, body: &[u8]) -> Vec<Value> {
    let request = StreamRequest::parse(line).unwrap().unwrap();
    let mut output = Vec::new();
    let _ = stream::serve(Some(service), request, &mut Cursor::new(body.to_vec()), &mut output);
    output
        .split(|byte| *byte == b'\n')
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_slice(line).unwrap())
        .collect()
}

#[test]
fn a_write_stream_commits_after_the_last_byte() {
    let root = TempRoot::new("wstream");
    let service = root.service();
    let line = json!({ "id": 1, "cmd": "fs.write", "path": root.at("up.bin"), "mode": "create",
        "stream": true, "size": 600_000 })
    .to_string();
    let body = vec![7u8; 600_000];
    let answers = stream_write(&service, &line, &body);
    assert_eq!(answers[0], json!({ "id": 1, "ok": true, "data": { "ready": true } }));
    assert_eq!(answers[1]["data"]["entry"]["size"], 600_000);
    assert_eq!(fs::read(root.path.join("up.bin")).unwrap(), body);
    assert_eq!(names_in(&root.path), ["up.bin"]);
}

/// RED (contract): a cancelled push leaves NO partial file at `path`.
#[test]
fn a_cancelled_write_stream_leaves_no_file() {
    let root = TempRoot::new("wcancel");
    let service = root.service();
    let line = json!({ "id": 1, "cmd": "fs.write", "path": root.at("up.bin"), "mode": "create",
        "stream": true, "size": 1_000_000 })
    .to_string();
    let answers = stream_write(&service, &line, &[1u8; 300_000]);
    assert_eq!(answers.len(), 1, "only the ready line; the stream ended early");
    assert_eq!(names_in(&root.path), Vec::<String>::new(), "no target and no temporary file");
    root.file("kept.txt", b"old");
    let line = json!({ "id": 1, "cmd": "fs.write", "path": root.at("kept.txt"),
        "mode": "overwrite", "stream": true, "size": 10 })
    .to_string();
    stream_write(&service, &line, b"new");
    assert_eq!(fs::read(root.path.join("kept.txt")).unwrap(), b"old", "the old file is untouched");
    assert_eq!(names_in(&root.path), ["kept.txt"]);
}

#[test]
fn a_write_stream_is_refused_before_any_byte_when_the_mode_fails() {
    let root = TempRoot::new("wrefuse");
    root.file("a.txt", b"x");
    let line = json!({ "id": 3, "cmd": "fs.write", "path": root.at("a.txt"), "mode": "create",
        "stream": true, "size": 5 })
    .to_string();
    let answers = stream_write(&root.service(), &line, b"hello");
    assert_eq!(answers.len(), 1);
    assert_eq!(answers[0]["error_code"], "fs.exists");
    let missing = json!({ "id": 3, "cmd": "fs.write", "path": root.at("b"), "mode": "create",
        "stream": true })
    .to_string();
    assert!(matches!(StreamRequest::parse(&missing), Some(Err((_, FsError::ParamsInvalid(_))))));
}

#[test]
fn a_read_stream_sends_header_bytes_and_end() {
    let root = TempRoot::new("rstream");
    let body: Vec<u8> = (0..700_000u32).map(|i| (i % 251) as u8).collect();
    root.file("big.bin", &body);
    let line = json!({ "id": 1, "cmd": "fs.read", "path": root.at("big.bin"), "offset": 100,
        "stream": true })
    .to_string();
    let request = StreamRequest::parse(&line).unwrap().unwrap();
    let mut output = Vec::new();
    stream::serve(Some(&root.service()), request, &mut Cursor::new(Vec::new()), &mut output)
        .unwrap();
    let header_end = output.iter().position(|b| *b == b'\n').unwrap();
    let header: Value = serde_json::from_slice(&output[..header_end]).unwrap();
    assert_eq!(header["data"]["size"], 700_000);
    assert_eq!(header["data"]["length"], 699_900);
    let bytes = &output[header_end + 1..header_end + 1 + 699_900];
    assert_eq!(bytes, &body[100..]);
    let end: Value =
        serde_json::from_slice(output[header_end + 1 + 699_900..].trim_ascii()).unwrap();
    assert_eq!(end["data"]["revision"], header["data"]["revision"]);
    assert!(StreamRequest::parse(r#"{"id":1,"cmd":"fs.read","path":"/x"}"#).is_none());
}

#[test]
fn errors_use_the_v12_envelope() {
    let mismatch =
        stream::answer(&json!(1), Err(FsError::RevisionMismatch { current: Some("s1-m2".into()) }));
    assert_eq!(
        mismatch,
        json!({ "id": 1, "ok": false, "error": "the file changed since it was read",
            "error_code": "fs.revision_mismatch", "error_details": { "current": "s1-m2" } })
    );
    assert_eq!(
        stream::answer(&json!(1), Ok(json!({}))),
        json!({ "id": 1, "ok": true, "data": {} })
    );
}

/// Review fix: a read whose text would escape to far more bytes than it
/// holds (control characters) is answered in base64, so an answer stays
/// near 4/3 of the bytes read.
#[test]
fn a_control_heavy_text_is_answered_in_base64() {
    let root = TempRoot::new("escape");
    root.file("ctl.txt", &[1u8; 3000]);
    let read = call(
        &root.service(),
        "fs.read",
        json!({ "path": root.at("ctl.txt"), "offset": 0, "max_bytes": 3000 }),
    )
    .unwrap();
    assert_eq!(read["encoding"], "base64");
    assert!(read.get("text").is_none());
}

/// Review fix: nested targets in one delete (a folder and a file inside
/// it) succeed; the second is already gone.
#[test]
fn a_delete_of_nested_targets_succeeds() {
    let root = TempRoot::new("nested");
    root.file("d/inner.txt", b"x");
    call(
        &root.service(),
        "fs.delete",
        json!({ "paths": [root.at("d"), root.at("d/inner.txt")], "permanent": true }),
    )
    .unwrap();
    assert_eq!(names_in(&root.path), Vec::<String>::new());
}

/// Review fix: a request path with a control character is refused, so a
/// write cannot make a file that a listing hides.
#[test]
fn a_path_with_a_control_character_is_refused() {
    let root = TempRoot::new("ctlname");
    let path = format!("{}/bad\u{7}name", root.path.display());
    assert!(matches!(
        call(&root.service(), "fs.write", json!({ "path": path, "text": "x", "mode": "create" })),
        Err(FsError::ParamsInvalid(_))
    ));
    assert_eq!(names_in(&root.path), Vec::<String>::new());
}

fn age(path: &Path, seconds: u64) {
    let when = std::time::SystemTime::now() - std::time::Duration::from_secs(seconds);
    fs::File::options().write(true).open(path).unwrap().set_modified(when).unwrap();
}

/// Daemon start: leftover write temporaries older than an hour are
/// removed; fresh ones, other names, and anything behind a symlink stay.
#[test]
fn stale_write_temporaries_are_swept_at_start() {
    let root = TempRoot::new("sweep");
    let outside = TempRoot::new("sweep-outside");
    let old = ".a.txt.cmux-0123456789abcdef.tmp";
    root.file(old, b"x");
    root.file(&format!("deep/er/{old}"), b"x");
    root.file(".b.txt.cmux-fedcba9876543210.tmp", b"fresh");
    root.file(".c.txt.cmux-short.tmp", b"x");
    root.file("notes.txt", b"x");
    outside.file(old, b"x");
    symlink(&outside.path, root.path.join("out")).unwrap();
    for path in [
        root.path.join(old),
        root.path.join("deep/er").join(old),
        root.path.join(".c.txt.cmux-short.tmp"),
        root.path.join("notes.txt"),
        outside.path.join(old),
    ] {
        age(&path, 2 * 60 * 60);
    }
    assert_eq!(root.service().sweep_stale_temporaries(), 2);
    assert!(!root.path.join(old).exists());
    assert!(!root.path.join("deep/er").join(old).exists());
    assert!(root.path.join(".b.txt.cmux-fedcba9876543210.tmp").exists(), "fresh: a running write");
    assert!(root.path.join(".c.txt.cmux-short.tmp").exists(), "not our name shape");
    assert!(root.path.join("notes.txt").exists());
    assert!(outside.path.join(old).exists(), "a symlink is never followed");
}
