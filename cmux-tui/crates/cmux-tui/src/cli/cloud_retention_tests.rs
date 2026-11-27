use serde_json::json;

use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn keep_takes_a_target_and_off() {
    assert_eq!(
        parse(KEEP, &words(&["--target", "machine:vm-1"])),
        Ok(Parsed::Keep { machine: "vm-1".into(), keep: true })
    );
    assert_eq!(
        parse(KEEP, &words(&["--target=machine:vm-1", "--off"])),
        Ok(Parsed::Keep { machine: "vm-1".into(), keep: false })
    );
    assert!(parse(KEEP, &words(&[])).is_err());
    assert!(parse(KEEP, &words(&["--target", "machine:"])).is_err());
    assert!(parse(KEEP, &words(&["--target", "machine:vm-1", "--confirm"])).is_err());
    assert_eq!(parse(KEEP, &words(&["--help"])), Ok(Parsed::Help(KEEP_USAGE)));
}

#[test]
fn archive_needs_confirm() {
    assert!(parse(ARCHIVE, &words(&["--target", "machine:vm-1"])).is_err());
    assert_eq!(
        parse(ARCHIVE, &words(&["--target", "machine:vm-1", "--confirm"])),
        Ok(Parsed::Archive { machine: "vm-1".into() })
    );
    assert!(parse(ARCHIVE, &words(&["--target", "machine:vm-1", "--confirm", "--off"])).is_err());
}

#[test]
fn each_verb_is_one_cloud_app_op_with_a_key() {
    let keep =
        op_of(&Parsed::Keep { machine: "vm-1".into(), keep: false }, Some("k".into())).unwrap();
    assert_eq!(
        (keep.app.as_str(), keep.op.as_str(), keep.args, keep.idempotency_key.as_deref()),
        ("cmux/cloud", "cloud.machine.keep", json!({"machine": "vm-1", "keep": false}), Some("k"))
    );
    let archive = op_of(&Parsed::Archive { machine: "vm-1".into() }, None).unwrap();
    assert_eq!(archive.op, "cloud.machine.archive_delete");
    assert_eq!(archive.args, json!({"machine": "vm-1"}));
    assert!(archive.idempotency_key.is_some_and(|key| key.starts_with("cli-")));
}

#[test]
fn an_archive_the_cli_may_not_run_says_where_the_app_offers_it() {
    let refused =
        Outcome::Answer(json!({"ok": false, "error_code": "apps.gesture_required", "error": "x"}));
    let (stdout, stderr, code) =
        answer(&Parsed::Archive { machine: "vm-1".into() }, &refused, OutputMode::Human);
    assert_eq!((stdout, code), (None, 1));
    assert!(stderr.unwrap().contains("machine:vm-1"));
    let (_, stderr, _) =
        answer(&Parsed::Archive { machine: "vm-1".into() }, &refused, OutputMode::Json);
    let error: Value = serde_json::from_str(&stderr.unwrap()).unwrap();
    assert_eq!(error["code"], "cloud.gesture_required");
}

#[test]
fn a_done_keep_says_what_changed() {
    let done =
        Outcome::Answer(json!({"ok": true, "data": {"machine": {"id": "vm-1", "name": "dev"}}}));
    let (stdout, _, code) =
        answer(&Parsed::Keep { machine: "vm-1".into(), keep: true }, &done, OutputMode::Human);
    assert_eq!(code, 0);
    assert!(stdout.unwrap().contains("dev (machine:vm-1)"));
    let (stdout, _, _) =
        answer(&Parsed::Keep { machine: "vm-1".into(), keep: true }, &done, OutputMode::Json);
    assert!(stdout.unwrap().contains("\"vm-1\""));
}
