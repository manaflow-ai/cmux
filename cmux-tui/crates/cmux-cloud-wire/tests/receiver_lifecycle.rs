use cmux_cloud_wire::{
    CloudVmReceiverLifecycleError, CloudVmReceiverLifecycleOp, CloudVmReceiverLifecycleParams,
    CloudVmReceiverLifecycleResult, OpRequest, OpResponse,
};
use serde_json::json;

#[test]
fn receiver_lifecycle_wire_requests_omit_absent_preconditions_and_replay_keys() {
    for params in [
        json!({"machine": "vm_00000000000000000000", "phase": "read"}),
        json!({"machine": "vm_00000000000000000000", "phase": "begin", "expected": "a".repeat(64), "attempt": "b".repeat(32)}),
        json!({"machine": "vm_00000000000000000000", "phase": "ready", "expected": "c".repeat(64)}),
        json!({"machine": "vm_00000000000000000000", "phase": "end", "expected": "c".repeat(64)}),
    ] {
        let typed: CloudVmReceiverLifecycleParams = serde_json::from_value(params.clone()).unwrap();
        let request = OpRequest::new::<CloudVmReceiverLifecycleOp>(typed);
        assert_eq!(
            serde_json::to_value(request).unwrap(),
            json!({"op": "cloud.vm.receiver.lifecycle", "params": params})
        );
    }
}

#[test]
fn receiver_lifecycle_wire_accepts_terminal_and_conflict_replies_without_a_revision() {
    for outcome in [
        json!({"ok": true, "value": {"machine": "vm_00000000000000000000", "generation": "a".repeat(64), "phase": "stopped"}}),
        json!({"ok": false, "error": {"code": "revision.conflict", "message": "stale generation", "retryable": false}}),
    ] {
        let mut response = json!({"op": "cloud.vm.receiver.lifecycle", "transaction": "tx", "replayed": false, "idempotency_key": "", "stream": "team:team_x", "sequence": 4});
        response.as_object_mut().unwrap().extend(outcome.as_object().unwrap().clone());
        let typed: OpResponse<CloudVmReceiverLifecycleResult, CloudVmReceiverLifecycleError> =
            serde_json::from_value(response.clone()).unwrap();
        assert_eq!(serde_json::to_value(typed).unwrap(), response);
    }
}
