//! fs-v1 review rule: a kick or shutdown after the daemon's rename but
//! before its answer line gives the client EOF although the file changed.
//! After an EOF on `fs.write` the client reconciles with `fs.stat` and never
//! reports a write that happened as a plain failure.

use cmux_cloud::fs::link_files::{ANSWER_LOST, write_reconciled};
use cmux_cloud::fs::{Cancel, DaemonFiles, DialTarget, LinkDaemonFiles};
use serde_json::{Value, json};
use std::path::PathBuf;

/// A `/bin/sh` stand-in for `cmux link dial`: an `fs.write` line gets no
/// answer (EOF after the daemon acted); an `fs.stat` line gets `stat`, or
/// EOF too when `stat` is empty.
#[cfg(unix)]
fn eof_on_write(name: &str, stat: &str) -> DialTarget {
    let dir: PathBuf =
        std::env::temp_dir().join(format!("cx-write-eof-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let wrapper = dir.join("dial.sh");
    let script = format!(
        r#"#!/bin/sh
printf '%s\n' '{{"ok":true,"path_state":"direct"}}' >&2
IFS= read -r line
case "$line" in
  *'"cmd":"fs.write"'*) exit 0 ;;
  *'"cmd":"fs.stat"'*) test -n '{stat}' && printf '%s\n' '{stat}'; exit 0 ;;
esac
exit 9
"#
    );
    std::fs::write(&wrapper, script).unwrap();
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(&wrapper, std::fs::Permissions::from_mode(0o700)).unwrap();
    DialTarget {
        binary: wrapper,
        host: "host-vm-alpha01".into(),
        socket: dir.join("link.sock"),
        env: vec![("PATH".into(), "/usr/bin:/bin".into())],
    }
}

fn stat_answer(revision: &str, size: u64) -> String {
    json!({ "id": 1, "ok": true, "data": { "kind": "file", "name": "a.txt", "mtime": 1,
        "revision": revision, "size": size } })
    .to_string()
}

fn write(target: &DialTarget, params: Value, len: u64) -> Result<Value, cmux_cloud::api::CloudError> {
    write_reconciled(&LinkDaemonFiles, target, params, len, &Cancel::default())
}

#[cfg(unix)]
#[test]
fn an_answer_lost_on_any_op_is_typed_and_retryable() {
    let target = eof_on_write("stat-eof", "");
    let err = LinkDaemonFiles
        .call(&target, "fs.stat", json!({ "path": "/a" }), &Cancel::default())
        .unwrap_err();
    assert_eq!(err.code, ANSWER_LOST, "{err:?}");
    assert!(err.retryable);
}

#[cfg(unix)]
#[test]
fn a_create_that_landed_answers_its_entry_from_stat() {
    let target = eof_on_write("create-landed", &stat_answer("s2-m1", 2));
    let data = write(
        &target,
        json!({ "path": "/home/cmux/a.txt", "bytes_base64": "aGk=", "mode": "create" }),
        2,
    )
    .expect("the write landed");
    assert_eq!(data["entry"]["revision"], "s2-m1");
}

#[cfg(unix)]
#[test]
fn a_create_with_no_file_did_not_land_and_is_retryable() {
    let missing = json!({ "id": 1, "ok": false, "error": "no such file or folder",
        "error_code": "fs.not_found" })
    .to_string();
    let target = eof_on_write("create-missing", &missing);
    let err = write(
        &target,
        json!({ "path": "/home/cmux/a.txt", "bytes_base64": "aGk=", "mode": "create" }),
        2,
    )
    .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_down", "{err:?}");
    assert!(err.retryable, "nothing changed: the same write may run again");
}

#[cfg(unix)]
#[test]
fn a_replace_that_left_the_expected_revision_did_not_land() {
    let target = eof_on_write("replace-unchanged", &stat_answer("s12-m1", 12));
    let err = write(
        &target,
        json!({ "path": "/home/cmux/a.txt", "bytes_base64": "aGk=", "mode": "replace",
            "expected": "s12-m1" }),
        2,
    )
    .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.link_down", "{err:?}");
    assert!(err.retryable);
}

#[cfg(unix)]
#[test]
fn a_replace_that_landed_answers_its_entry_from_stat() {
    let target = eof_on_write("replace-landed", &stat_answer("s2-m5", 2));
    let data = write(
        &target,
        json!({ "path": "/home/cmux/a.txt", "bytes_base64": "aGk=", "mode": "replace",
            "expected": "s12-m1" }),
        2,
    )
    .expect("the write landed");
    assert_eq!(data["entry"]["revision"], "s2-m5");
}

#[cfg(unix)]
#[test]
fn a_file_another_writer_changed_is_a_conflict_with_its_revision() {
    let target = eof_on_write("replace-other", &stat_answer("s40-m9", 40));
    let err = write(
        &target,
        json!({ "path": "/home/cmux/a.txt", "bytes_base64": "aGk=", "mode": "replace",
            "expected": "s12-m1" }),
        2,
    )
    .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.conflict", "{err:?}");
    assert_eq!(err.details, Some(json!({ "current": "s40-m9" })));
}

#[cfg(unix)]
#[test]
fn a_stat_that_also_fails_is_indeterminate() {
    let target = eof_on_write("stat-fails", "");
    let err = write(
        &target,
        json!({ "path": "/home/cmux/a.txt", "bytes_base64": "aGk=", "mode": "overwrite" }),
        2,
    )
    .unwrap_err();
    assert_eq!(err.code, "cmux.cloud.indeterminate", "{err:?}");
    assert!(!err.retryable, "the file may have changed: no blind retry");
}
