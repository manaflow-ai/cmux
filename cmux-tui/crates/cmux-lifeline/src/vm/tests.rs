use super::*;

#[test]
fn vm_lifecycle_wire_rejects_unrecognized_and_missing_states() {
    for raw in [
        "\"runing\"",
        "\"ready\"",
        "\"attached\"",
        "\"preclaimed\"",
        "\"claimed\"",
        "\"\"",
        "null",
        "42",
        "{}",
    ] {
        assert!(serde_json::from_str::<Status>(raw).is_err(), "{raw}");
    }
    assert_eq!(serde_json::from_str::<Status>("\"unknown\"").unwrap(), Status::Unknown);
    assert_eq!(serde_json::from_str::<Status>("\"destroyed\"").unwrap(), Status::Destroyed);
}

#[test]
fn vm_lifecycle_retains_identity_through_claim_pause_resume_and_delete() {
    let vm = Vm::<Unallocated, _>::new(String::from("allocation-with-idempotency-key"));
    let vm = vm.provision().preclaim().claim().into_vm().running().ready().attach();
    let vm = vm.pause().paused().resume().running().ready().attach().detach();
    let deleted = vm.delete().deleted();
    assert_eq!(deleted.payload(), "allocation-with-idempotency-key");
}

#[test]
fn vm_lifecycle_running_observation_does_not_imply_attach_readiness() {
    let status: Status = serde_json::from_str("\"running\"").unwrap();
    let Observed::Running(vm) = status.bind("vm-a") else { panic!("not running") };
    let attached = vm.ready().attach();
    assert_eq!(*attached.payload(), "vm-a");
}

#[test]
fn vm_lifecycle_failed_provisioning_keeps_a_cleanup_capability() {
    let vm = Vm::<Unallocated, _>::new("vm-a").provision().failed();
    let deleted = vm.delete().deleted();
    assert_eq!(*deleted.payload(), "vm-a");
}

#[test]
fn vm_lifecycle_wire_roundtrips_every_provider_state() {
    for status in Status::ALL {
        let raw = serde_json::to_string(&status).unwrap();
        assert_eq!(serde_json::from_str::<Status>(&raw).unwrap(), status);
        assert_eq!(status.as_str().parse::<Status>().unwrap(), status);
    }
    assert!("runing".parse::<Status>().is_err());
    assert_eq!("deleted".parse::<Status>().unwrap(), Status::Destroyed);
}

#[test]
fn vm_lifecycle_operation_failure_is_not_vm_failure() {
    // The Cloud mutation contract restores running on pause failure and paused
    // on resume failure. An accepted mutation is not a terminal receipt.
    let running = Vm::observed_running("vm-a");
    let running = running.pause().running();
    let paused = running.pause().paused();
    let paused = paused.resume().paused();
    assert_eq!(*paused.payload(), "vm-a");
    let deleted = paused.delete().deleted();
    assert_eq!(*deleted.payload(), "vm-a");
}

#[test]
fn vm_lifecycle_uncertain_mutation_retains_identity_for_reconciliation() {
    let vm = Vm::observed_running(String::from("vm-a"));
    // An unanswered pause may have succeeded remotely. It cannot return a
    // running capability or claim failure; reconcile the retained subject.
    let unknown = vm.uncertain();
    let Observed::Paused(paused) = unknown.observed(Status::Paused) else {
        panic!("authoritative pause observation was lost")
    };
    let running = paused.resume().running();
    assert_eq!(running.payload(), "vm-a");
}

#[test]
fn vm_lifecycle_proxy_connection_needs_remote_identification() {
    let connection = Vm::connected("proxy-to-vm-a");
    let attached = connection.ready().attach();
    assert_eq!(*attached.payload(), "proxy-to-vm-a");
}

#[test]
fn vm_lifecycle_claim_and_release_preserve_provider_power() {
    let Observed::Paused(vm) = Status::Paused.bind(String::from("paused-spare")) else {
        panic!("not paused")
    };
    let paused: Vm<Paused, _> = vm.preclaim().claim().release();
    assert_eq!(paused.payload(), "paused-spare");
    let running: Vm<Running, _> = paused.resume().running().preclaim().release();
    assert_eq!(running.payload(), "paused-spare");
}

#[test]
fn vm_lifecycle_edges_are_listed_once() {
    let mut seen = std::collections::HashSet::new();
    for edge in EDGES {
        assert!(seen.insert((edge.from, edge.method)), "{edge:?} declared twice");
    }
    assert_eq!(EDGES.len(), 43);
}
