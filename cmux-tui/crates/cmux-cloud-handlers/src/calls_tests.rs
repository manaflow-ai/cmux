//! Parity with the app's `CloudResizeDiskTests` and every branch of [`resize_call`].

use super::*;
use serde_json::json;

fn given(value: Value) -> Args {
    value.as_object().cloned().unwrap_or_default()
}

#[test]
fn disk_only_sends_only_disk_mb() {
    let call = resize_call(&given(json!({ "disk": 100 })), "m-1").unwrap();
    assert_eq!(call.args, json!({ "machine": "m-1", "size": { "disk_mb": 100 * 1024 } }));
    assert_eq!(Value::Object(call.fields), json!({ "disk_gib": 100 }));
}

#[test]
fn disk_as_text_reads_as_its_number() {
    let call = resize_call(&given(json!({ "disk": " 64 " })), "m-1").unwrap();
    assert_eq!(call.args["size"], json!({ "disk_mb": 64 * 1024 }));
}

#[test]
fn size_and_disk_go_in_one_call() {
    let call = resize_call(&given(json!({ "size": "large", "disk": 128 })), "m-2").unwrap();
    assert_eq!(
        call.args,
        json!({ "machine": "m-2", "size": { "cpu": 8, "memory_mb": 16384, "disk_mb": 131072 } })
    );
    assert_eq!(Value::Object(call.fields), json!({ "size": "large", "disk_gib": 128 }));
}

#[test]
fn size_only_sends_cpu_and_memory() {
    let call = resize_call(&given(json!({ "size": "small" })), "m-3").unwrap();
    assert_eq!(call.args["size"], json!({ "cpu": 2, "memory_mb": 4096 }));
    assert_eq!(Value::Object(call.fields), json!({ "size": "small" }));
}

#[test]
fn refusals_are_the_checks() {
    assert_eq!(resize_call(&given(json!({})), "m").unwrap_err().key, "resizeNeedsSizeOrDisk");
    assert_eq!(
        resize_call(&given(json!({ "disk": 6 })), "m").unwrap_err().key,
        "resizeNeedsSizeOrDisk"
    );
    assert_eq!(
        resize_call(&given(json!({ "size": "huge" })), "m").unwrap_err().key,
        "sizeMustBeOneOf"
    );
}
