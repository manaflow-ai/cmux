use super::*;
use serde_json::json;

#[test]
fn finds_paused_lease_in_host_record_or_tags() {
    assert_eq!(
        paused_lease(&json!({"host": {"lease": {"leaseId": "l1", "state": "paused"}}})),
        Some("l1".into())
    );
    assert_eq!(
        paused_lease(&json!({"host": {"lease": "l2", "state": "paused"}})),
        Some("l2".into())
    );
    assert_eq!(paused_lease(&json!({"tags": {"lease": "l3"}, "status": "idle"})), None);
}

#[test]
fn the_configured_wake_host_passes_the_egress_gate_and_nothing_else_does() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let config = MachineWakeConfig {
        enabled: true,
        base_url: "https://machine-wake-named-test.org/".into(),
        token: None,
    };
    assert_eq!(
        wake_url(&config, "l1"),
        "https://machine-wake-named-test.org/v1/machines/leases/l1/wake"
    );
    assert!(cmux_egress::check("machine-wake-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("unrelated-machine-wake-test.org", "test").is_err());
}
