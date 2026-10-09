//! Cell pixel metrics during terminal spawn and spawn failure exit reasons.

use super::*;

#[test]
fn cell_pixel_metric_publishes_only_after_existing_surface_fanout() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let observed_at_publish = Arc::new(Mutex::new(Vec::new()));
    *mux.cell_pixel_before_publish.lock().unwrap() = Some(Arc::new({
        let observed_at_publish = observed_at_publish.clone();
        move |metric| observed_at_publish.lock().unwrap().push(metric)
    }));

    let update = mux.set_cell_pixel_size(9, 18);

    assert_eq!(*observed_at_publish.lock().unwrap(), vec![(8, 16)]);
    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert_eq!(surface.test_cell_pixel_size(), (9, 18));
    assert_eq!(update.resizes, vec![(surface.id, (80, 24), 0)]);
    assert!(update.failures.is_empty());
}

#[test]
fn unchanged_cell_pixel_result_must_match_the_requested_metric() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    *mux.cell_pixel_operation.lock().unwrap() = Some(Arc::new(|_, _, _| Ok(None)));

    let update = mux.set_cell_pixel_size(9, 18);

    assert!(update.resizes.is_empty());
    assert_eq!(update.failures.len(), 1);
    assert_eq!(update.failures[0].surface, surface.id);
    assert!(
        update.failures[0].error.contains("did not converge"),
        "unexpected failure: {}",
        update.failures[0].error
    );
    assert_eq!(mux.cell_pixel_size(), (8, 16));
    assert_eq!(surface.test_cell_pixel_size(), (8, 16));
}

#[test]
fn terminal_spawn_releases_cell_pixel_lifecycle_and_reconciles_before_publish() {
    let mux = test_mux();
    let observed_unlocked = Arc::new(Mutex::new(Vec::new()));
    *mux.terminal_spawn_after_cell_pixel_snapshot.lock().unwrap() = Some(Arc::new({
        let mux = Arc::downgrade(&mux);
        let observed_unlocked = observed_unlocked.clone();
        move |unlocked| {
            observed_unlocked.lock().unwrap().push(unlocked);
            if unlocked {
                mux.upgrade().unwrap().set_cell_pixel_size(9, 18);
            }
        }
    }));

    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    assert_eq!(*observed_unlocked.lock().unwrap(), vec![true]);
    assert_eq!(mux.cell_pixel_size(), (9, 18));
    assert_eq!(surface.test_cell_pixel_size(), (9, 18));
}

fn spawn_terminal_with_cell_pixel_failure(
    mux: &Arc<Mux>,
    fail_exit_persistence: bool,
) -> (String, anyhow::Result<Arc<Surface>>) {
    *mux.terminal_spawn_after_cell_pixel_snapshot.lock().unwrap() = Some(Arc::new({
        let mux = Arc::downgrade(mux);
        move |unlocked| {
            assert!(unlocked, "terminal spawn retained the cell-pixel lifecycle lock");
            mux.upgrade().unwrap().set_cell_pixel_size(9, 18);
        }
    }));
    *mux.terminal_spawn_before_cell_pixel_reconcile.lock().unwrap() = Some(Arc::new({
        let mux = Arc::downgrade(mux);
        move |surface| {
            surface.fail_next_test_master_resize();
            if fail_exit_persistence {
                mux.upgrade()
                    .unwrap()
                    .workspace_registry
                    .lock()
                    .unwrap()
                    .set_terminal_exit_failure(true)
                    .unwrap();
            }
        }
    }));
    let workspace =
        mux.create_empty_workspace(Some("cell-pixel-failure".into()), None, None).unwrap();
    let terminal_id = TerminalId::random().unwrap();
    let terminal_hex = terminal_id.to_hex();
    let reservation = TerminalReservationRequest {
        terminal_id,
        mutation: WorkspaceMutation::daemon("cell-pixel-failure", "test").unwrap(),
        fingerprint: serde_json::json!({"test":"cell-pixel-failure"}),
        expected_generation: None,
        expected_revision: None,
        on_exit: TerminalOnExit::Close,
        env: Vec::new(),
    };
    let result = mux.spawn_surface_in_workspace_reserved(
        &workspace.key,
        None,
        Some((80, 24)),
        None,
        reservation,
    );
    (terminal_hex, result)
}

#[test]
fn terminal_spawn_cell_pixel_failure_uses_stable_exit_reason() {
    let mux = test_mux();
    let (terminal_id, result) = spawn_terminal_with_cell_pixel_failure(&mux, false);

    let error = result.expect_err("injected cell-pixel failure must abort terminal creation");
    assert!(format!("{error:#}").contains("injected PTY master resize failure"));
    let exited = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_record(&terminal_id)
        .unwrap()
        .unwrap()
        .exit
        .unwrap();
    assert_eq!(
        exited["outcome"],
        serde_json::json!({
            "kind":"unknown",
            "reason":"cell-pixel-reconcile-failed",
        })
    );
    assert!(!exited.to_string().contains("injected PTY master resize failure"));
}

#[test]
fn terminal_spawn_cell_pixel_failure_propagates_exit_persistence_error() {
    let mux = test_mux();
    let (_, result) = spawn_terminal_with_cell_pixel_failure(&mux, true);

    let error = result.expect_err("injected persistence failure must abort terminal creation");
    assert!(
        format!("{error:#}")
            .contains("could not persist terminal exit after cell-pixel reconciliation failed"),
        "unexpected terminal creation error: {error:#}"
    );
}
