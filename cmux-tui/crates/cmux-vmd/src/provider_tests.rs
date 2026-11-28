use super::*;

#[test]
fn labels_pick_egress_and_size() {
    let mut spec =
        CreateMachineSpec { name: "a".into(), image: Some("img".into()), labels: BTreeMap::new() };
    assert_eq!(spec_body(&spec, true)["egress"]["mode"], "none");
    assert_eq!(spec_body(&spec, true)["image"], "img");
    assert!(spec_body(&spec, false).get("image").is_none());
    spec.labels.insert("cmux.vmd/egress".into(), "internet".into());
    spec.labels.insert("cmux.vmd/vcpus".into(), "4".into());
    let b = spec_body(&spec, true);
    assert_eq!(b["egress"]["mode"], "internet");
    assert_eq!(b["vcpus"], 4);
}

#[test]
fn error_codes_map_to_trait_errors() {
    let e = map_error(
        MachineOperation::Delete,
        "m1",
        404,
        &json!({"error": {"code": "machine_not_found", "message": "x"}}),
    );
    assert!(
        matches!(e, MachineProviderError::MachineNotFound(MachineHandle(ref id)) if id == "m1")
    );
    let url = reqwest::Url::parse("http://h:1/v1/snapshots/s9/fork").unwrap();
    assert_eq!(subject_id(&url), "s9");
    let e = map_error(
        MachineOperation::Exec,
        "m1",
        409,
        &json!({"error": {"code": "invalid_state", "message": "cannot exec on a paused machine"}}),
    );
    assert!(matches!(e, MachineProviderError::InvalidState { .. }));
    let e = map_error(MachineOperation::Create, "", 500, &Value::Null);
    assert!(matches!(e, MachineProviderError::Backend(_)));
}
