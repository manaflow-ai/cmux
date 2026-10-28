//! `server-stats` `terminal_models` (H12, steps 1-2): every live terminal
//! is counted once by its process model, a hosted one by why it runs on a
//! terminal host, and a failed holder start is counted and kept.

use super::*;
use crate::surface::HostOrigin;

fn hosted(
    mux: &Arc<Mux>,
    id: SurfaceId,
    adopted: bool,
) -> (Arc<Surface>, std::os::unix::net::UnixStream) {
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
    let surface = Surface::spawn_hosted(
        id,
        SurfaceOptions::default(),
        Arc::downgrade(mux),
        HostedSurfaceLaunch {
            adopted,
            attachment,
            kitty_reservation: None,
            terminate_on_error: false,
            defer_launch_activation: false,
            lifetime: PtyLifetime::SessionOwned,
            terminal_public_id: None,
            resource_identity: None,
        },
    )
    .unwrap();
    (surface, host)
}

#[test]
fn every_live_terminal_is_counted_once_by_model_and_host_origin() {
    let mux = Mux::new_for_test("terminal-models", SurfaceOptions::default());
    let local =
        Surface::spawn_for_test(9_901, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let (launched, _launched_host) = hosted(&mux, 9_902, false);
    let (adopted, _adopted_host) = hosted(&mux, 9_903, true);
    let (adopted_two, _adopted_two_host) = hosted(&mux, 9_904, true);
    assert_eq!(launched.as_pty().unwrap().host_origin, HostOrigin::Launched);
    assert_eq!(adopted.as_pty().unwrap().host_origin, HostOrigin::Adopted);
    for surface in [&local, &launched, &adopted, &adopted_two] {
        mux.insert_surface_runtime_for_test(surface.clone());
    }
    let counts = mux.terminal_models();
    assert_eq!(
        (counts.daemon, counts.host_launched, counts.host_adopted, counts.holder),
        (1, 1, 2, 0),
        "{counts:?}"
    );
    assert!(matches!(counts.model, "holder" | "hosts"), "{counts:?}");
    assert_ne!(counts.model_reason, "unknown", "{counts:?}");
}

const FAILED_START_CHILD_ENV: &str = "CMUX_TERMINAL_MODELS_FAILED_START_CHILD";

/// Runs [`a_failed_holder_start_child`] in its own process with the holder
/// model on (the model is fixed per process at its first read).
#[test]
fn a_failed_holder_start_is_counted_and_kept_and_starts_no_host() {
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "surface::tests::terminal_models::a_failed_holder_start_child",
            "--nocapture",
        ])
        .env(FAILED_START_CHILD_ENV, "1")
        .env("CMUX_TUI_TERMINAL_HOST_MODEL", "holder")
        .status()
        .unwrap();
    assert!(status.success(), "the child failed (see its output above)");
}

#[test]
fn a_failed_holder_start_child() {
    if std::env::var_os(FAILED_START_CHILD_ENV).is_none() {
        return;
    }
    assert!(crate::holder_runtime::enabled(), "the child runs the holder model");
    let mux = Mux::new_for_test("terminal-models-failed-start", SurfaceOptions::default());
    // A host root that is a file: the holder service cannot open it.
    let root = std::env::temp_dir()
        .join(format!("cmux-terminal-models-{}", crate::workspace_registry::new_uuid_v4()));
    std::fs::write(&root, b"not a directory").unwrap();
    let options =
        SurfaceOptions { terminal_host_root: Some(root.clone()), ..SurfaceOptions::default() };
    let spawned = Surface::spawn(9_910, options, Arc::downgrade(&mux));
    let _ = std::fs::remove_file(&root);
    assert!(spawned.is_err(), "a holder start that cannot run must fail, not fall back");
    let counts = mux.terminal_models();
    assert_eq!(counts.model, "holder", "{counts:?}");
    assert_eq!(counts.holder_start_failures, 1, "{counts:?}");
    assert!(counts.last_holder_start_failure.is_some(), "{counts:?}");
    assert_eq!(counts.host_launched, 0, "no host started instead: {counts:?}");
}
