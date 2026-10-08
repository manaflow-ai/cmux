use super::*;

#[test]
fn authority_rotation_waits_for_an_authorized_lifecycle_mutation() {
    const MUX_GENERATION: &str = "0123456789abcdef0123456789abcdef";
    const AUTHORITY_ONE: &str = "locked-authority-one-0000000000000000001";
    const AUTHORITY_TWO: &str = "locked-authority-two-0000000000000000002";

    let mux = Mux::new_provider_managed_pending_for_test(
        "authority-lock-test",
        SurfaceOptions::default(),
        MUX_GENERATION,
    );
    mux.install_or_rotate_provider_workspace_authority(
        MUX_GENERATION,
        0,
        1,
        ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
    )
    .unwrap();
    let workspace = mux.create_empty_workspace(Some("managed".into()), None, None).unwrap();
    let (locked_tx, locked_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let release_rx = Arc::new(Mutex::new(release_rx));
    *mux.workspace_close_after_selector_resolution.lock().unwrap() = Some(Arc::new(move || {
        locked_tx.send(()).unwrap();
        release_rx.lock().unwrap().recv().unwrap();
    }));

    let close = std::thread::spawn({
        let mux = mux.clone();
        let key = workspace.key.clone();
        move || {
            mux.close_provider_managed_workspace_authorized(
                &Actor::Daemon,
                workspace.workspace,
                &key,
                AUTHORITY_ONE,
            )
            .unwrap()
        }
    });
    locked_rx.recv().unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::sync_channel(1);
    let (rotated_tx, rotated_rx) = std::sync::mpsc::sync_channel(1);
    let rotate = std::thread::spawn({
        let mux = mux.clone();
        move || {
            started_tx.send(()).unwrap();
            let result = mux.install_or_rotate_provider_workspace_authority(
                MUX_GENERATION,
                1,
                2,
                ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
            );
            rotated_tx.send(()).unwrap();
            result
        }
    });
    started_rx.recv().unwrap();
    assert!(rotated_rx.recv_timeout(Duration::from_millis(50)).is_err());
    release_tx.send(()).unwrap();
    assert_eq!(close.join().unwrap(), Some(2));
    rotate.join().unwrap().unwrap();
    rotated_rx.recv().unwrap();
    mux.authorize_provider_workspace_authority(AUTHORITY_TWO).unwrap();
    *mux.workspace_close_after_selector_resolution.lock().unwrap() = None;
}
