//! The machine cap card (moved from the app's CloudMachineCapTests; the app keeps the create
//! flow's, which runs its closures).

use serde_json::json;

use super::*;
use crate::record::{IdlePauseDiagnostics, Status};

fn refused() -> Value {
    json!({
        "resource": "active", "limit": 2, "used": 2,
        "busy": [
            {"machine": "vm_b", "name": "paint", "last_active_at": 1_800_000_000_000_i64},
            {"machine": "vm_a", "name": null, "last_active_at": 1_700_000_000_000_i64},
            {"machine": "", "name": "no id"},
        ],
    })
}

#[test]
fn the_servers_cap_refusal_names_the_busy_machines() {
    let details = refused();
    let cap = refusal("cmux.cloud.quota_exceeded", Some(&details)).unwrap();
    assert_eq!(
        cap.busy,
        [
            Busy {
                machine: "vm_b".into(),
                name: "paint".into(),
                last_active_at: Some(1_800_000_000_000.0)
            },
            Busy {
                machine: "vm_a".into(),
                name: "vm_a".into(),
                last_active_at: Some(1_700_000_000_000.0)
            },
        ]
    );
    assert!(!cap.free_plan);
    assert!(refusal("cloud.quota.exceeded", None).is_some(), "upstream's spelling, no details");
    assert!(refusal("cmux.cloud.plan_required", None).is_none());
    let vm_limit = json!({"limit": 20, "team_vms": 20, "orphans": 3});
    assert!(
        refusal("cloud.quota.vm_limit", Some(&vm_limit)).is_none(),
        "the VM limit counts paused machines: Pause and Upgrade free nothing"
    );
    assert!(
        refusal("cmux.cloud.quota_exceeded", Some(&json!({"resource": "snapshots"}))).is_none(),
        "another quota is not the machine cap"
    );
    assert!(
        refusal("cmux.cloud.quota_exceeded", Some(&json!({"resource": 3}))).is_some(),
        "an unreadable resource is the machine cap"
    );
}

fn owned(id: &str, status: Status, user: &str) -> Machine {
    let mut machine = Machine::new(id, status);
    machine.created_by = Some(user.into());
    machine
}

#[test]
fn the_classic_card_lists_only_the_persons_own_running_machines() {
    let mut mine = owned("vm_mine", Status::Running, "alice");
    mine.display_name = Some("paint".into());
    let mut pausing = owned("vm_pausing", Status::Running, "alice");
    pausing.pending_change = Some(Status::Pausing);
    let machines = [
        mine.clone(),
        owned("vm_bob", Status::Running, "bob"),
        owned("vm_paused", Status::Paused, "alice"),
        pausing,
    ];
    let cap = plan(false, true, &machines, Some("alice"));
    assert_eq!(
        cap.busy.iter().map(|busy| busy.machine.as_str()).collect::<Vec<_>>(),
        ["vm_mine"],
        "never a teammate's machine, nor one not running"
    );
    assert_eq!(cap.busy[0].name, "paint");
    assert!(busy_machines(std::slice::from_ref(&mine), None).is_empty());
    assert!(busy_machines(std::slice::from_ref(&mine), Some("")).is_empty());
    assert_eq!(plan(true, true, &[mine], Some("alice")), Cap { busy: Vec::new(), free_plan: true });
}

#[test]
fn the_classic_card_offers_pause_only_where_pausing_frees_room() {
    let mine = owned("vm_mine", Status::Running, "alice");
    assert_eq!(
        plan(false, false, std::slice::from_ref(&mine), Some("alice")),
        Cap::default(),
        "a Pause that frees no slot was offered"
    );
    assert_eq!(plan(false, true, &[mine], Some("alice")).busy.len(), 1);
}

#[test]
fn the_busy_machines_are_newest_activity_first() {
    let mut api = owned("vm_api", Status::Running, "alice");
    api.idle_pause = Some(IdlePauseDiagnostics {
        minutes: 30,
        last_checked_at: None,
        idle_since: None,
        last_api_activity_at: Some(3_000),
        private_address_known: true,
        last_decision: None,
    });
    api.running_since = Some(1.0);
    let mut started = owned("vm_started", Status::Starting, "alice");
    started.running_since = Some(2_000.0);
    let never = owned("vm_never", Status::Provisioning, "alice");
    let busy = busy_machines(&[never, started, api], Some("alice"));
    assert_eq!(
        busy.iter().map(|busy| busy.machine.as_str()).collect::<Vec<_>>(),
        ["vm_api", "vm_started", "vm_never"]
    );
    assert_eq!(
        busy[0].last_active_at,
        Some(3_000.0),
        "the API activity wins over the running start"
    );
}

#[test]
fn a_create_that_made_room_names_the_paused_machine() {
    let answer = json!({"machine": {"id": "vm_new"}, "made_room": {"machine": {"id": "vm_old", "name": "paint"}}});
    assert_eq!(made_room(&answer).unwrap()["id"], "vm_old");
    assert!(made_room(&json!({"machine": {}})).is_none());
}
