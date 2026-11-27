use super::*;
use crate::surface::{Surface, SurfaceOptions};
use std::sync::Weak;

#[cfg(unix)]
fn ended_terminal() -> Arc<Surface> {
    Surface::exited_terminal_placeholder(
        9,
        SurfaceOptions { cols: 20, rows: 4, ..SurfaceOptions::default() },
        Weak::new(),
        crate::terminal_host_runtime::TerminalHostIdentity {
            terminal_id: "00000000000040008000000000000009".into(),
            incarnation: "10000000000040008000000000000009".into(),
        },
    )
    .unwrap()
}

/// The budget pass measured every terminal through a lock that rebuilds a
/// parked mirror, so an ended tab nobody views came back to full size on the
/// next pass (919 of 1176 at n1000). It measures a parked one as nothing and
/// leaves it parked.
#[cfg(unix)]
#[test]
fn a_budget_pass_leaves_a_parked_mirror_parked() {
    let surface = ended_terminal();
    surface
        .try_with_terminal(|terminal| terminal.vt_write(b"one\r\ntwo\r\nthree\r\nfour\r\nfive"))
        .unwrap();
    assert!(measure_live(&surface).is_some(), "an unparked terminal is measured");
    assert!(surface.park_exited_mirror());
    assert_eq!(measure_live(&surface), None);
    assert!(
        surface.try_with_live_terminal(|terminal| terminal.set_scrollback_max_bytes(1)).is_none()
    );
    assert!(surface.mirror_parked(), "the pass did not rebuild it");
    // A viewer's lock still brings it back.
    let text = surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
    assert!(text.contains("five"), "{text:?}");
    assert!(!surface.mirror_parked());
    assert!(measure_live(&surface).is_some());
}
