//! Unit tests for the `Mux` coordinator. Topic suites live in `mux/tests/`;
//! this module holds their shared fixtures.

use super::*;

#[cfg(unix)]
#[test]
fn live_authority_install_and_rotation_preserve_open_pty() {
    const MUX_GENERATION: &str = "0123456789abcdef0123456789abcdef";
    const AUTHORITY_ONE: &str = "live-authority-one-00000000000000000001";
    const AUTHORITY_TWO: &str = "live-authority-two-00000000000000000002";

    fn wait_for_text(surface: &Surface, needle: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let text = surface.with_terminal(|terminal| terminal.plain_text()).unwrap().unwrap();
            if text.contains(needle) {
                return;
            }
            assert!(Instant::now() < deadline, "PTY did not emit {needle:?}; output: {text:?}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    let mux = Mux::new_provider_managed_pending(
        "authority-pty-test",
        SurfaceOptions::default(),
        MUX_GENERATION,
    )
    .unwrap();
    let workspace = mux.create_empty_workspace(Some("pty".into()), None, None).unwrap();
    let (surface, _) = mux
        .create_terminal_surface_in_workspace(
            &Actor::Daemon,
            workspace.workspace,
            Some(vec![
                "sh".into(),
                "-c".into(),
                "while IFS= read -r line; do printf 'authority-test:%s\\n' \"$line\"; done".into(),
            ]),
            None,
            None,
            Some((80, 24)),
        )
        .unwrap();
    let process_id = surface.process_id();
    surface.write_bytes(b"before\n").unwrap();
    wait_for_text(&surface, "authority-test:before");

    mux.install_or_rotate_provider_workspace_authority(
        MUX_GENERATION,
        0,
        41,
        ProviderWorkspaceAuthority::new(AUTHORITY_ONE).unwrap(),
    )
    .unwrap();
    mux.install_or_rotate_provider_workspace_authority(
        MUX_GENERATION,
        41,
        42,
        ProviderWorkspaceAuthority::new(AUTHORITY_TWO).unwrap(),
    )
    .unwrap();

    surface.write_bytes(b"after\n").unwrap();
    wait_for_text(&surface, "authority-test:after");
    assert_eq!(surface.process_id(), process_id);
    assert!(!surface.is_dead());
    mux.shutdown();
}
