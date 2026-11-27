//! A network reservation is not a completed enrollment, and its private code
//! must never disappear while the public result reports successful pairing.
use cmux_server_core::pairing::enrollment::read_frame;
use serde_json::{Value, json};

fn frame() -> Value {
    json!({
        "t":"paired", "host":"host_00000000000000000001", "team":"team_00000000000000000001",
        "user":"user_00000000000000000001", "install":"inst_00000000000000000001",
        "network":{"state":"reserved","tenant":"native_team","mesh":"mesh_00000000000000000000000000","device":"dev_00000000000000000000000000"},
        "network_enrollment":{
            "origin":"https://vm.example.test","code":"msc_00000000000000000000000000",
            "tenantId":"native_team","meshId":"mesh_00000000000000000000000000","deviceId":"dev_00000000000000000000000000",
            "expiresAt":"2026-10-19T12:10:00.000Z",
            "binding":{"name":"server","wgPublicKey":"AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=",
                "installPublicKey":"BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}
        }
    })
}

#[test]
fn server_pairing_native_requires_the_private_grant_for_a_network_reservation() {
    let mut value = frame();
    value.as_object_mut().unwrap().remove("network_enrollment");
    assert!(
        read_frame(&value.to_string()).is_err(),
        "a reserved network was silently treated as completed basic pairing"
    );
}

#[test]
fn server_pairing_native_requires_public_reservation_metadata_for_a_private_grant() {
    let mut value = frame();
    value.as_object_mut().unwrap().remove("network");
    assert!(read_frame(&value.to_string()).is_err());
}

#[test]
fn server_pairing_native_refuses_confused_tenant_mesh_and_device_locators() {
    for field in ["tenant", "mesh", "device"] {
        let mut value = frame();
        value["network"][field] = json!("another-identity");
        assert!(read_frame(&value.to_string()).is_err(), "accepted a mismatched {field}");
    }
}

#[test]
fn server_pairing_native_refuses_non_https_or_non_origin_api_targets() {
    for origin in [
        "http://vm.example.test",
        "https://user@vm.example.test",
        "https://vm.example.test/elsewhere",
        "https://vm.example.test?code=secret",
    ] {
        let mut value = frame();
        value["network_enrollment"]["origin"] = json!(origin);
        assert!(read_frame(&value.to_string()).is_err(), "accepted an unsafe API origin");
    }
}

#[test]
fn server_pairing_native_refuses_gateway_codes_and_invalid_public_bindings() {
    for (field, bad) in [("code", "mec_00000000000000000000000000"), ("expiresAt", "never")] {
        let mut value = frame();
        value["network_enrollment"][field] = json!(bad);
        assert!(read_frame(&value.to_string()).is_err());
    }
    let mut value = frame();
    value["network_enrollment"]["binding"]["name"] = json!("server:injected");
    assert!(read_frame(&value.to_string()).is_err());
}

#[test]
fn server_pairing_native_debug_and_basic_public_result_do_not_show_invitation_codes() {
    let result = read_frame(&frame().to_string()).unwrap().unwrap();
    let shown = format!("{result:?}");
    assert!(!shown.contains("msc_00000000000000000000000000"));
}

#[test]
fn server_pairing_native_saved_registration_refuses_injected_signing_fields() {
    let grant = frame()["network_enrollment"].clone();
    let valid = json!({"origin":grant["origin"],"tenant":grant["tenantId"],
        "mesh":grant["meshId"],"device":grant["deviceId"],
        "wg_public_key":grant["binding"]["wgPublicKey"],
        "install_public_key":grant["binding"]["installPublicKey"]});
    for (field, bad) in
        [("device", "device\ninjected-purpose"), ("install_public_key", "key\ninjected-message")]
    {
        let mut value = valid.clone();
        value[field] = json!(bad);
        let registration: cmux_server_core::pairing::native::Registration =
            serde_json::from_value(value).unwrap();
        let mut signed = false;
        assert!(
            registration
                .policy_proof(1_792_411_200_000, [1; 16], |_| {
                    signed = true;
                    Err("must not reach signer".into())
                })
                .is_err()
        );
        assert!(!signed);
    }
}
