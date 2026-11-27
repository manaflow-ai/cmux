//! The plan's machine facts (moved from the app's CloudPhoneDirectoryFactsTests).

use serde_json::json;

use super::*;

#[test]
fn only_a_named_paid_plan_with_open_machines_pays() {
    assert!(pays_for_cloud(Some("pro"), Some(3)));
    // No cap is not a closed plan.
    assert!(pays_for_cloud(Some("team"), None));
    assert!(!pays_for_cloud(Some("free"), Some(3)));
    assert!(!pays_for_cloud(Some("FREE"), Some(3)));
    assert!(!pays_for_cloud(Some(""), Some(3)));
    assert!(!pays_for_cloud(Some("pro"), Some(0)));
    assert!(!pays_for_cloud(None, Some(3)));
}

#[test]
fn each_limits_field_reads_on_its_own() {
    let limits = read(&json!({
        "maxActiveVms": 3, "activeVmCount": 1, "planId": "pro",
        "memoryOptionsMb": [8192, 4096, 4096, 0, -1], "vcpusByMemoryMb": {"4096": 2, "8192": 4, "x": 1, "16384": 0},
        "lockedMemoryOptionsMb": [16384],
    }));
    assert_eq!(limits.max_active_vms, Some(3));
    assert_eq!(limits.active_vm_count, 1);
    assert_eq!(limits.plan_id.as_deref(), Some("pro"));
    assert_eq!(limits.memory_options_mb, [4096, 8192]);
    assert_eq!(limits.vcpus_by_memory_mb, BTreeMap::from([("4096".into(), 2), ("8192".into(), 4)]));
    assert_eq!(limits.locked_memory_options_mb, Some(vec![16384]));
    let odd = read(
        &json!({"maxActiveVms": "x", "activeVmCount": null, "memoryOptionsMb": ["a"], "vcpusByMemoryMb": {"4096": "two"}}),
    );
    assert_eq!(odd, Limits::default(), "an unreadable cap reads as none");
}
