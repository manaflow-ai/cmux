use super::*;
use crate::{ProviderError, ProviderErrorCode, RequestEnvelope, ResponseEnvelope};

const V2_3: ProtocolRange = ProtocolRange { min: 2, max: 3 };

#[test]
fn this_build_speaks_its_own_version() {
    assert!(ProtocolRange::OURS.contains(crate::PROTOCOL_VERSION));
    assert!(PROTOCOL_MIN <= PROTOCOL_MAX);
    assert_eq!(ProtocolRange::OURS.versions().last(), Some(&PROTOCOL_MAX));
}

#[test]
fn the_window_keeps_n_minus_1_once_a_second_version_exists() {
    // A build that drops a version must still speak the one before its newest.
    if PROTOCOL_MAX > 1 {
        assert!(PROTOCOL_MIN < PROTOCOL_MAX, "PROTOCOL_MIN must stay at most PROTOCOL_MAX - 1");
    }
}

#[test]
fn an_n_minus_1_client_gets_its_version() {
    // Provider at 2..=3, client one release behind speaking only 2.
    assert_eq!(negotiate_version(V2_3, &[2]), Ok(2));
}

#[test]
fn an_n_plus_1_client_gets_the_newest_common_version() {
    // Client one release ahead speaks 3 and 4; the provider tops out at 3.
    assert_eq!(negotiate_version(V2_3, &[3, 4]), Ok(3));
    // Order in the list does not matter.
    assert_eq!(negotiate_version(V2_3, &[4, 2, 3]), Ok(3));
}

#[test]
fn a_legacy_single_version_client_still_negotiates() {
    // Every build before the range sent `supported_versions: [1]`.
    assert_eq!(negotiate_version(ProtocolRange::OURS, &[1]), Ok(1));
    assert_eq!(ProtocolRange::spanning(&[1]), Some(ProtocolRange { min: 1, max: 1 }));
}

#[test]
fn no_overlap_is_a_typed_refusal_naming_the_older_side() {
    let older_client = negotiate_version(V2_3, &[1]).unwrap_err();
    assert_eq!(older_client.update(), UpdateSide::Peer);
    assert_eq!(older_client.action(), "update cmux");

    let newer_client = negotiate_version(V2_3, &[4, 5]).unwrap_err();
    assert_eq!(newer_client.update(), UpdateSide::This);
    assert_eq!(newer_client.action(), "update this machine provider");

    let error = newer_client.to_provider_error();
    assert_eq!(error.code, ProviderErrorCode::VersionIncompatible);
    assert!(!error.retryable);
    assert!(error.message.contains("4..=5"), "{}", error.message);
    assert!(error.message.contains("2..=3"), "{}", error.message);
}

#[test]
fn an_empty_version_list_is_refused_with_either_side() {
    let refusal = negotiate_version(V2_3, &[]).unwrap_err();
    assert_eq!(refusal.update(), UpdateSide::Either);
    assert_eq!(refusal.action(), "update this machine provider or cmux");
}

#[test]
fn the_wire_code_round_trips_and_old_builds_read_it() {
    let error = ProviderError {
        code: ProviderErrorCode::VersionIncompatible,
        message: "m".into(),
        retryable: false,
    };
    let json = serde_json::to_value(&error).unwrap();
    assert_eq!(json["code"], "version.incompatible");
    let back: ProviderError = serde_json::from_value(json).unwrap();
    assert_eq!(back.code, ProviderErrorCode::VersionIncompatible);
    // A pre-range build's decoder takes any valid code as `Other`; the dot is allowed there.
    assert!(crate::valid_error_code("version.incompatible"));
}

#[test]
fn a_frame_outside_the_range_peeks_as_a_refusal_not_a_decode_error() {
    let frame = serde_json::json!({
        "protocol": "cmux.machine-provider",
        "version": 9,
        "id": "cmux-1",
        "result": {"anything": true},
    });
    let peek: VersionPeek = serde_json::from_value(frame.clone()).unwrap();
    let refusal = peek.check(ProtocolRange::OURS, "machine provider").unwrap();
    assert_eq!(refusal.update(), UpdateSide::This);
    assert_eq!(refusal.action(), "update cmux");
    // The strict envelope decoder still refuses it: the peek is what makes it typed.
    assert!(serde_json::from_value::<ResponseEnvelope<serde_json::Value>>(frame).is_err());
}

#[test]
fn a_frame_in_range_peeks_clean_and_decodes() {
    let envelope = RequestEnvelope::new(
        crate::OpaqueId::new("cmux-1".to_string()).unwrap(),
        crate::ProviderRequest::Snapshot(crate::SnapshotParams { known_revision: None }),
    );
    let bytes = serde_json::to_vec(&envelope).unwrap();
    let peek: VersionPeek = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(peek.check(ProtocolRange::OURS, "cmux"), None);
    let back: RequestEnvelope = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(back, envelope);
}
