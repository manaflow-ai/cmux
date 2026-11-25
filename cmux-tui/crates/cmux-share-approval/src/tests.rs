//! The asker's half builds exactly the approval the shared vectors hold, and it
//! travels as the JSON the target reads back.

use serde_json::Value;

use super::*;

fn vectors() -> Vec<Value> {
    let vectors: Vec<Value> =
        serde_json::from_str(include_str!("../../acpmux/src/share_approval_vectors.json")).unwrap();
    assert!(!vectors.is_empty());
    vectors
}

fn asked_like(vector: &Value) -> ShareApproval {
    let field = |name: &str| vector["approval"][name].as_str().unwrap().to_owned();
    ShareApproval::asked(
        Device { id: &field("target"), name: &field("target_name") },
        Device { id: &field("asker"), name: &field("asker_name") },
        &field("confirmed_by"),
        field("confirmed_at").parse().unwrap(),
        &field("nonce"),
    )
    .unwrap()
}

#[test]
fn asked_builds_the_vectors_canonical_and_wire() {
    for vector in vectors() {
        let approval = asked_like(&vector);
        assert_eq!(approval.canonical(), vector["canonical"].as_str().unwrap());
        // Unsigned it travels exactly as the vector's approval (signature "").
        assert_eq!(approval.wire(), vector["approval"]);
        let back: ShareApproval = serde_json::from_value(approval.wire()).unwrap();
        assert_eq!(back, approval);
    }
}

#[test]
fn signed_changes_only_the_signature() {
    let vector = &vectors()[0];
    let approval = asked_like(vector);
    let signed = approval.clone().signed("c2ln");
    assert_eq!(signed.signature, "c2ln");
    assert_eq!(signed.canonical(), approval.canonical());
    assert_eq!(signed.wire()["signature"], "c2ln");
    assert_eq!(signed.wire()["confirmed_at"], vector["approval"]["confirmed_at"]);
}

#[test]
fn confirmed_at_reads_a_number_or_a_decimal_string() {
    let mut wire = vectors()[0]["approval"].clone();
    wire["confirmed_at"] = serde_json::json!(1_794_700_000u64);
    let approval: ShareApproval = serde_json::from_value(wire.clone()).unwrap();
    assert_eq!(approval.confirmed_at, 1_794_700_000);
    wire["confirmed_at"] = serde_json::json!(1.5);
    assert!(serde_json::from_value::<ShareApproval>(wire).is_err());
}

#[test]
fn asked_refuses_what_no_target_could_admit() {
    let mac = Device { id: "mac", name: "Studio" };
    let phone = Device { id: "phone", name: "iPhone" };
    let code = |target: Device<'_>, asker: Device<'_>, account: &str, nonce: &str| {
        ShareApproval::asked(target, asker, account, 1, nonce).unwrap_err().code
    };
    assert_eq!(code(Device { id: " ", name: "" }, phone, "user", "n"), "share.no_target");
    assert_eq!(code(mac, Device { id: "", name: "" }, "user", "n"), "share.no_device");
    assert_eq!(code(mac, phone, "", "n"), "share.signed_out");
    assert_eq!(code(mac, mac, "user", "n"), "share.self");
    assert_eq!(code(mac, phone, "user", ""), "share.no_nonce");
    assert_eq!(code(mac, phone, "user\nnonce=x", "n"), "share.bad_field");
    let ok = ShareApproval::asked(mac, phone, " user ", 7, "n").unwrap();
    assert_eq!((ok.confirmed_by.as_str(), ok.signature.as_str()), ("user", ""));
}

#[test]
fn a_control_approval_signs_its_own_first_line() {
    let ask = |version| {
        ShareApproval::asked_for(
            version,
            Device { id: "mac", name: "Studio" },
            Device { id: "phone", name: "iPhone" },
            "user_1",
            1_794_700_000,
            "n1",
        )
    };
    let (share, control) = (ask(VERSION).unwrap(), ask(CONTROL_VERSION).unwrap());
    assert_eq!(control.v, CONTROL_VERSION);
    assert!(control.canonical().starts_with("cmux.control-approval.v1\ntarget=mac\n"));
    assert_ne!(share.canonical(), control.canonical(), "one tap signs one grant");
    assert_eq!(ask("cmux.other.v1").unwrap_err().code, "share.bad_version");
}
