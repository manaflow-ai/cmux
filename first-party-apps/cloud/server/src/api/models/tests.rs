//! The records the server relays are the generated `cmux.wire/1` types,
//! with what the catalog does not say kept (shapes from
//! backend/catalog/cloud-vectors.json).

use super::{
    ConnectFacts, Machine, MachineExtra, Revision, VM_KIND_UNKNOWN, decode_connect_info, order,
};
use crate::api::{codes, decode_answer};
use cmux_cloud_wire::CloudMachineStatus;
use serde_json::{Value, json};
use std::cmp::Ordering;

/// A `CloudMachine` as the vectors' `machine.list.first_page` has it.
fn record(id: &str, revision: &str) -> Value {
    json!({
        "id": id, "team": "team_t0000000000000000001", "creator": "user_u0000000000000000001",
        "name": "build box", "size": { "cpu": 2, "memory_mb": 4096, "disk_mb": 16384 },
        "status": "running", "image": { "id": "img_i0000000000000000001", "daemon_version": "0.40.0" },
        "host": "host_h0000000000000000001", "classic": false, "created_at": 1_790_000_001_000i64,
        "last_active_at": 1_790_000_601_000i64, "idle_policy": { "idle_seconds": 1800 },
        "error": null, "hourly_rate_usd": 0.1322, "running_since": 1_790_000_301_000i64,
        "revision": revision
    })
}

fn with(mut value: Value, fields: Value) -> Value {
    for (key, field) in fields.as_object().expect("fields") {
        value[key] = field.clone();
    }
    value
}

fn decode(value: Value) -> Machine {
    serde_json::from_value(value).expect("machine decodes")
}

fn encode(machine: &Machine) -> Value {
    serde_json::to_value(machine).expect("machine encodes")
}

#[test]
fn a_catalog_record_relays_every_field_as_it_came() {
    let source = with(
        record("vm-1", "7"),
        json!({ "pause_reason": null, "desktop": true, "paused_hourly_rate_usd": 0.0014 }),
    );
    let machine = decode(source.clone());
    assert_eq!(machine.record.status, CloudMachineStatus::Running);
    let encoded = encode(&machine);
    for (key, value) in source.as_object().expect("record") {
        assert_eq!(&encoded[key], value, "{key}");
    }
}

#[test]
fn fields_the_catalog_lacks_reach_the_app() {
    let idle = json!({
        "minutes": 30, "lastCheckedAt": 1_700_000_000_000i64, "privateAddressKnown": true,
        "lastDecision": { "outcome": "idle", "run": { "checked": 8, "elapsedMs": 120 } }
    });
    let source = with(
        record("vm-1", "2"),
        json!({
            "platform": { "os": "linux", "arch": "x86_64" },
            "capabilities": ["terminal", "agent_session"],
            "provider_operations": ["snapshot", "resize"],
            "idlePause": idle,
        }),
    );
    let machine = decode(source.clone());
    assert!(machine.has_capability("agent_session"));
    assert!(!machine.has_capability("provider_secret"));
    let encoded = encode(&machine);
    for key in ["platform", "capabilities", "provider_operations", "idlePause"] {
        assert_eq!(encoded[key], source[key], "{key}");
    }

    // The older names read as the ones the app reads (cmux-cloud-machine `from_next`).
    let older = decode(with(
        record("vm-2", "3"),
        json!({ "providerCapabilities": ["snapshot"], "idle_pause": { "minutes": 0 } }),
    ));
    let encoded = encode(&older);
    assert_eq!(encoded["provider_operations"], json!(["snapshot"]));
    assert_eq!(encoded["idlePause"], json!({ "minutes": 0 }));

    // A record without them keeps the shape it had before.
    let plain = encode(&decode(record("vm-3", "4")));
    assert_eq!(plain["platform"], Value::Null);
    assert_eq!(plain["capabilities"], json!([]));
    assert!(plain.get("provider_operations").is_none());
    assert!(plain.get("idlePause").is_none());
}

#[test]
fn the_extra_fields_never_shadow_a_catalog_field() {
    // Every catalog field present (the optional ones too).
    let full =
        decode(with(record("vm-1", "1"), json!({ "pause_reason": "idle", "desktop": true })));
    let catalog = serde_json::to_value(&full.record).expect("record encodes");
    let extra = serde_json::to_value(MachineExtra {
        platform: Some(super::MachinePlatform::default()),
        capabilities: vec!["x".into()],
        provider_operations: vec!["x".into()],
        idle_pause: Some(json!({})),
    })
    .expect("extra encodes");
    for key in extra.as_object().expect("extra").keys() {
        assert!(
            catalog.get(key).is_none(),
            "{key} is a catalog field now: drop it from MachineExtra"
        );
    }
    assert_eq!(catalog["pause_reason"], "idle");
}

#[test]
fn a_record_missing_a_catalog_required_field_is_a_bad_response() {
    for field in [
        "team",
        "creator",
        "size",
        "status",
        "image",
        "classic",
        "created_at",
        "idle_policy",
        "revision",
    ] {
        let mut source = record("vm-1", "1");
        source.as_object_mut().expect("record").remove(field);
        let error = decode_answer::<Machine>("cloud.machine.get", source).expect_err(field);
        assert_eq!(error.code, codes::BAD_RESPONSE, "{field}");
    }
    // The catalog's nullable fields may be absent.
    let mut source = record("vm-1", "1");
    for field in ["name", "host", "last_active_at", "error", "hourly_rate_usd", "running_since"] {
        source.as_object_mut().expect("record").remove(field);
    }
    assert!(decode_answer::<Machine>("cloud.machine.get", source).is_ok());
}

#[test]
fn a_status_this_build_does_not_know_passes_through() {
    let encoded = encode(&decode(with(record("vm-1", "1"), json!({ "status": "hibernating" }))));
    assert_eq!(encoded["status"], "hibernating");
}

#[test]
fn revisions_order_as_numbers() {
    assert_eq!(order("9", "10"), Ordering::Less);
    assert_eq!(order("10", "9"), Ordering::Greater);
    assert_eq!(order("007", "7"), Ordering::Equal);
    assert_eq!(order("0", "000"), Ordering::Equal);
    assert_eq!(order("123456789012345678901", "99"), Ordering::Greater);
    assert_eq!(order("19", "20"), Ordering::Less);
    let rev = |s: &str| Revision::try_from(s.to_owned()).expect("decimal");
    assert!(rev("010") > rev("9"));
    assert_eq!(rev("000").as_str(), "0");
    assert!(Revision::try_from("1a".to_owned()).is_err());
    assert!(Revision::try_from(String::new()).is_err());
}

#[test]
fn a_machine_revision_is_a_checked_decimal() {
    assert_eq!(decode(record("vm-1", "007")).revision(), "7");
    for bad in ["", "7a", "-1", " 7"] {
        let error =
            decode_answer::<Machine>("cloud.machine.get", record("vm-1", bad)).expect_err(bad);
        assert_eq!(error.code, codes::BAD_RESPONSE, "{bad:?}");
    }
}

/// The vectors' `machine.connect_info` answer.
fn connect_info() -> Value {
    json!({
        "machine": "vm_m0000000000000000001", "host": "host_h0000000000000000001", "epoch": 1,
        "state": "running",
        "peer": { "wg_public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "overlay_address": "fd7c:6d78::1", "vpc_endpoint": null, "public_ipv6": null },
        "gateway": null, "services": ["daemon", "ssh"],
        "daemon": { "version": "0.40.0", "capabilities": ["fs-v1"] },
        "vm_kind": "owner", "revision": "7"
    })
}

const OP: &str = "cloud.machine.connect_info";

#[test]
fn only_the_exact_owner_value_owns_the_vm() {
    for (value, owns) in
        [("owner", true), ("team", false), ("Owner", false), (" owner", false), ("", false)]
    {
        let info = decode_connect_info(OP, with(connect_info(), json!({ "vm_kind": value })))
            .expect("decodes");
        assert_eq!(info.caller_owns_vm(), owns, "{value:?}");
    }
}

#[test]
fn a_vm_kind_absent_or_not_a_string_reads_as_unknown() {
    for bad in [json!(true), json!(1), json!(["owner"]), json!({ "kind": "owner" }), json!(null)] {
        let info = decode_connect_info(OP, with(connect_info(), json!({ "vm_kind": bad.clone() })))
            .expect("decodes");
        assert!(!info.caller_owns_vm(), "{bad}");
        assert_eq!(info.vm_kind.as_str(), VM_KIND_UNKNOWN);
    }
    let mut older = connect_info();
    older.as_object_mut().expect("info").remove("vm_kind");
    let info = decode_connect_info(OP, older).expect("a Worker that predates vm_kind");
    assert!(!info.caller_owns_vm());
    assert_eq!(serde_json::to_value(&info).expect("encodes")["vm_kind"], VM_KIND_UNKNOWN);
}

#[test]
fn a_connect_info_missing_a_catalog_required_field_is_a_bad_response() {
    for field in ["machine", "host", "epoch", "state", "peer", "services", "daemon", "revision"] {
        let mut source = connect_info();
        source.as_object_mut().expect("info").remove(field);
        let error = decode_connect_info(OP, source).expect_err(field);
        assert_eq!(error.code, codes::BAD_RESPONSE, "{field}");
    }
}

#[test]
fn a_connect_info_revision_is_a_checked_decimal() {
    let info = decode_connect_info(OP, with(connect_info(), json!({ "revision": "007" })))
        .expect("decodes");
    assert_eq!(info.revision, "7");
    for bad in ["", "7a", "-1", " 7"] {
        let error = decode_connect_info(OP, with(connect_info(), json!({ "revision": bad })))
            .expect_err(bad);
        assert_eq!(error.code, codes::BAD_RESPONSE, "{bad:?}");
    }
}

#[test]
fn capability_and_service_checks_are_exact_and_fail_closed() {
    let info = decode_connect_info(OP, connect_info()).expect("decodes");
    assert!(info.has_service("daemon"));
    assert!(info.daemon_has_capability("fs-v1"));
    assert!(!info.has_service("http"));
    assert!(!info.daemon_has_capability("fs-v2"));
}
