//! macOS process-scope scan tests for close-on-exec scope markers.

use super::*;

#[test]
fn mac_close_on_exec_marker_does_not_claim_an_unrelated_process() {
    // A fork copies the parent's close-on-exec scope markers and keeps them until it runs exec.
    // On macOS the scan read every vnode descriptor, so such a child (or the parent itself) was
    // claimed by the scope, and an unfinalized scope SIGKILLs a claimed process at once. That
    // killed a fresh `/bin/sleep 300` test terminal before exec, the test tree lost its screen,
    // and app::tests::double_click_selects_a_complete_word panicked on its active_screen()
    // (macOS job 129821773453 of run 42808325625). Linux checks the fd flags for this; macOS
    // must check the close-on-exec status of each descriptor too.
    //
    // This process holds the scope marker exactly as a child between fork and exec does: open,
    // with close-on-exec set. Model the ownership scan with it and an earlier, absent root; no
    // tracker is registered and no PID is killed.
    let scope = UnixProcessScope::prepare().unwrap();
    let registration = ScopeRegistration {
        marker: scope.marker.clone(),
        file_marker: scope.file_marker,
        _marker_fd: Arc::clone(&scope._marker_fd),
        root: ProcessIdentity { pid: u32::MAX, started: 0 },
        tracked: scope.tracked.clone(),
        track_before_finalization: true,
        final_scan_gate: None,
    };
    let current = process_identity(std::process::id()).unwrap();
    let scanned = scan_registered_processes(&[registration], ProcessScanCursor::default());
    // The whole process table fits one scan, so no match can hide behind a resume cursor.
    assert!(scanned.next.is_none(), "the scan finished in one pass");
    assert!(
        !scanned.matches.contains(&(0, current)),
        "a close-on-exec marker is incidental fork inheritance, not scope membership"
    );
}
