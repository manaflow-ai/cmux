use super::*;
use serde_json::json;

fn hello(abi: Option<u64>, min: Option<u64>) -> Value {
    let mut meta = serde_json::Map::new();
    if let Some(abi) = abi {
        meta.insert("abi".into(), json!(abi));
    }
    if let Some(min) = min {
        meta.insert("abiMin".into(), json!(min));
    }
    json!({"_meta": {"acpmux": meta}})
}

#[test]
fn the_window_keeps_n_minus_1() {
    // The build before this one (N-1) still talks to it: the floor never passes ABI - 1.
    assert!(ABI_MIN < crate::protocol::ABI.max(1));
    let ours = AbiRange::ours();
    let n_minus_1 = AbiRange { min: ABI_MIN.saturating_sub(1), max: crate::protocol::ABI - 1 };
    assert_eq!(ours.common(n_minus_1), Some(crate::protocol::ABI - 1));
}

#[test]
fn n_plus_1_that_still_serves_us_talks_at_ours() {
    // A newer daemon (N+1) whose floor is at or under our ABI talks at our ABI.
    let ours = AbiRange::ours();
    let next = AbiRange { min: crate::protocol::ABI, max: crate::protocol::ABI + 1 };
    assert_eq!(ours.common(next), Some(crate::protocol::ABI));
}

#[test]
fn a_peer_from_before_the_fields_is_abi_0_and_still_served() {
    let old = AbiRange::of(&hello(None, None));
    assert_eq!(old, AbiRange { min: 0, max: 0 });
    assert_eq!(AbiRange::ours().common(old), Some(0), "ABI_MIN 0 serves pre-field peers");
}

#[test]
fn a_missing_or_bad_floor_is_the_peers_one_revision() {
    assert_eq!(AbiRange::of(&hello(Some(2), None)), AbiRange { min: 2, max: 2 });
    assert_eq!(AbiRange::of(&hello(Some(2), Some(5))), AbiRange { min: 2, max: 2 });
    assert_eq!(AbiRange::of(&hello(Some(3), Some(1))), AbiRange { min: 1, max: 3 });
}

#[test]
fn no_overlap_is_refused_typed_naming_the_side_to_update() {
    let ours = AbiRange { min: 2, max: 3 };
    let older = AbiRange { min: 0, max: 1 };
    let newer = AbiRange { min: 4, max: 5 };
    assert_eq!(ours.common(older), None);
    assert_eq!(ours.common(newer), None);
    assert_eq!(update_side(ours, older), "peer");
    assert_eq!(update_side(ours, newer), "self");
    let refused = refusal(ours, older);
    let data = refused.data.clone().expect("typed");
    assert_eq!(data["errorKind"], json!(crate::recovery::kind::VERSION_INCOMPATIBLE));
    assert_eq!(data["details"]["update"], json!("peer"));
    assert!(data["recovery"].as_str().unwrap().contains("Update this client"), "{data}");
}
