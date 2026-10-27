//! Startup failures of an in-memory mux reach the caller as errors: the
//! daemon's constructor reads terminal-host records from disk, so an
//! unreadable host root must not panic the daemon.

use super::*;

#[test]
fn try_new_returns_an_error_when_the_terminal_host_root_is_unreadable() {
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-try-new-host-root-{}", crate::workspace_registry::new_uuid_v4()));
    // A file where the host-record directory belongs: read_dir fails with
    // an error other than NotFound.
    std::fs::write(&root, b"not a directory").unwrap();
    let options =
        SurfaceOptions { terminal_host_root: Some(root.clone()), ..SurfaceOptions::default() };

    let plain = Mux::try_new("try-new-unreadable-host-root", options.clone());
    let pending = Mux::new_provider_managed_pending(
        "try-new-unreadable-host-root-pending",
        options,
        "0123456789abcdef0123456789abcdef",
    );
    std::fs::remove_file(&root).unwrap();

    assert!(plain.is_err(), "an unreadable terminal-host root must fail try_new");
    assert!(pending.is_err(), "an unreadable terminal-host root must fail the pending constructor");
}
