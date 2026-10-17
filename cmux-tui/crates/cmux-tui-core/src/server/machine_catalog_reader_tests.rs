//! Old SDKs reject added fields and origin enum values. Exercise actual native
//! responses with a frozen strict decoder before enabling the richer catalog.

use super::*;
use serde::Deserialize;
use std::collections::BTreeMap;

// The target-base Python MachineSnapshot codec accepts exactly these fields
// and only origin=local (f1fde42e: bindings/python/cmux/resources.py).
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyMachine {
    id: String,
    name: String,
    origin: LegacyOrigin,
    status: String,
    connectable: bool,
    deleted: bool,
    recoverable: bool,
    #[serde(default)]
    extra: BTreeMap<String, Value>,
}

#[derive(Debug, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum LegacyOrigin {
    Local,
}

fn read(reader: &Publisher, mux: &Arc<Mux>, operation: &str, params: Value) -> Value {
    reader.frame(
        mux,
        json!({"protocol":"cmux.protocol/2","type":"request","id":"read",
        "operation":operation,"params":params}),
    )
}

fn assert_legacy(value: &Value, mux: &Arc<Mux>) {
    let decoded = serde_json::from_value::<LegacyMachine>(value.clone());
    assert!(decoded.is_ok(), "an unopted reader must retain its strict SDK shape: {decoded:?}");
    let machine = decoded.unwrap();
    assert_eq!(machine.id, mux.machine_public_id.as_str());
    assert_eq!(machine.name, "local");
    assert_eq!(machine.origin, LegacyOrigin::Local);
    assert_eq!(machine.status, "running");
    assert!(machine.connectable);
    assert!(!machine.deleted && !machine.recoverable);
    assert!(machine.extra.is_empty());
}

#[test]
fn cmux_next_machine_reader_legacy_decoder_control() {
    let mux = mux();
    assert_legacy(
        &json!({"id":mux.machine_public_id,"name":"local","origin":"local",
        "status":"running","connectable":true,"deleted":false,"recoverable":false}),
        &mux,
    );
}

#[test]
fn cmux_next_machine_reader_without_opt_in_keeps_the_local_wire_shape() {
    let mux = mux();
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    let reply = read(&reader, &mux, "machine.get", json!({"machine":"current"}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_legacy(&reply["result"], &mux);
}

#[test]
fn cmux_next_machine_reader_publication_does_not_change_an_old_readers_catalog() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    assert_eq!(publisher.send(&mux, 1, json!([remote()]))["ok"], true);
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    let reply = read(&reader, &mux, "machine.list", json!({}));
    assert_eq!(reply["ok"], true, "{reply}");
    let machines = reply["result"].as_array().unwrap();
    assert_eq!(machines.len(), 1, "remote enum variants require reader opt-in");
    assert_legacy(&machines[0], &mux);
}

#[test]
fn cmux_next_machine_reader_does_not_return_a_remote_shape_without_opt_in() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let remote = remote();
    assert_eq!(publisher.send(&mux, 1, json!([remote]))["ok"], true);
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    let reply = read(&reader, &mux, "machine.get", json!({"machine":remote["id"]}));
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "selector.not_found");
}

#[test]
fn cmux_next_machine_reader_explicit_catalog_opt_in_retains_owner_metadata() {
    let mux = mux();
    let identity = super::super::run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().contains(&json!("machine-catalog-read-v1"))
    );
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    let remote = remote();
    assert_eq!(publisher.send(&mux, 1, json!([remote]))["ok"], true);
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    let reply = read(&reader, &mux, "machine.list", json!({"catalog":true}));
    assert_eq!(reply["ok"], true, "explicit opt-in must be accepted: {reply}");
    assert_eq!(reply["result"].as_array().unwrap().len(), 2);
    assert!(reply["result"][0]["platform"]["os"].is_string());
    assert_eq!(reply["result"][1]["platform"], remote["platform"]);
    let selected =
        read(&reader, &mux, "machine.get", json!({"machine":remote["id"],"catalog":true}));
    assert_eq!(selected["ok"], true, "{selected}");
    assert_eq!(selected["result"], reply["result"][1]);
    let legacy = read(&reader, &mux, "machine.list", json!({}));
    assert_eq!(legacy["result"].as_array().unwrap().len(), 1, "opt-in is per request");
    assert_legacy(&legacy["result"][0], &mux);
}

#[test]
fn cmux_next_machine_reader_false_opt_in_and_session_snapshots_keep_the_legacy_shape() {
    let mux = mux();
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    let local = read(&reader, &mux, "machine.get", json!({"machine":"current","catalog":false}));
    assert_eq!(local["ok"], true, "{local}");
    assert_legacy(&local["result"], &mux);
    let snapshot =
        read(&reader, &mux, "session.snapshot", json!({"machine":"current","session":"current"}));
    assert_eq!(snapshot["ok"], true, "{snapshot}");
    assert_legacy(&snapshot["result"]["machine"], &mux);
}

#[test]
fn cmux_next_machine_reader_opt_in_is_typed_and_cannot_extend_session_routes() {
    let mux = mux();
    let reader = Publisher::new(&mux, ClientTransport::Unix, false);
    for catalog in [Value::Null, json!("true"), json!(1)] {
        let reply = read(&reader, &mux, "machine.list", json!({"catalog":catalog}));
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error"]["code"], "validation.invalid");
    }
    let session = read(&reader, &mux, "session.list", json!({"machine":"current","catalog":true}));
    assert_eq!(session["ok"], false, "{session}");
    assert_eq!(session["error"]["code"], "validation.invalid");
}
