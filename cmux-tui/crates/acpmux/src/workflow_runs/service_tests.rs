use super::*;

#[tokio::test]
async fn workflow_runs_gates_preserve_waiters_and_release_finished_runs() {
    let service = Service::default();
    let gate = service.gate("wf-live");
    let held = gate.clone().lock_owned().await;
    let waiter = service.gate("wf-live");
    assert!(Arc::ptr_eq(&gate, &waiter));
    assert!(waiter.try_lock().is_err());
    let old = Arc::downgrade(&gate);
    drop(gate);
    // A held guard must keep every new caller on the same lock.
    let again = service.gate("wf-live");
    assert!(Arc::ptr_eq(&waiter, &again));
    drop(held);
    let next = waiter.lock_owned().await;
    assert!(again.try_lock().is_err());
    drop(next);
    drop(again);
    assert!(old.upgrade().is_none(), "a finished run retained its operation lock");
}

#[test]
fn workflow_runs_gate_registry_does_not_grow_with_run_history() {
    let service = Service::default();
    let live = service.gate("wf-live");
    for index in 0..100 {
        drop(service.gate(&format!("wf-finished-{index}")));
    }
    assert!(
        service.gates.lock().unwrap().len() <= 2,
        "the gate registry retained completed run history"
    );
    assert!(Arc::ptr_eq(&live, &service.gate("wf-live")));
}
