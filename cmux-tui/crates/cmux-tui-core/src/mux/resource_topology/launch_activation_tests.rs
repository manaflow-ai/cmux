//! A created terminal's launch activation reaches its host when the new tab
//! left before the creation settled.
//!
//! A new terminal's host sends none of its shell's output until the daemon's
//! Activate frame (`wait_for_launch_owner_stream_ready`, with no deadline).
//! The daemon sends it after the creation's projection commit
//! (`activated_creation`). A tab strip change (a tab group close) takes no
//! creation fence, so it can remove the new tab in that window; the terminal
//! keeps running, detached (closing a view never ends a terminal). The
//! activation looked the terminal up through its tab only, found nothing and
//! returned Ok: the host then waited for ever and the terminal showed an
//! empty screen wherever it was shown again.

use std::time::Duration;

use super::*;
use crate::resource::TerminalPublicId;
use crate::terminal_host_protocol::{MAX_FRAME_PAYLOAD, MessageKind, read_frame};

#[cfg(unix)]
#[test]
fn a_created_terminal_whose_tab_left_before_settlement_still_activates_its_host() {
    let mux = Mux::new_for_test("launch-activation-tab-gone", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    // The create reserved the terminal (Launching) before it launched the host.
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&attachment.record.terminal_id, &workspace.key).unwrap();
    let terminal_id = TerminalPublicId::random().unwrap();
    let identity = TabResourceIdentity::terminal(Some(terminal_id.clone())).unwrap();
    let tab_id = identity.tab_id.clone();
    let surface = Surface::spawn_hosted_awaiting_activation_for_test(
        mux.next_id(),
        Arc::downgrade(&mux),
        attachment,
        identity,
    )
    .unwrap();
    {
        let mut state = mux.state.lock().unwrap();
        insert_surface_checked(&mut state, surface.clone()).unwrap();
        // The new tab leaves before the creation settles; its terminal stays.
        let (removed, _) = remove_surface(&mux, &mut state, surface.id);
        assert!(removed.is_some(), "the created tab was in the state");
        assert!(!state.resource_indexes.tabs.contains_key(&tab_id));
        assert!(
            state.terminal_catalog.get(&terminal_id).is_some(),
            "a view close keeps the terminal runtime"
        );
    }

    mux.activate_created_terminal_launch(&json!({
        "kind":"terminal",
        "tab_id":tab_id,
        "terminal_id":terminal_id,
    }))
    .unwrap();

    host.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut kinds = Vec::new();
    while let Ok(Some(frame)) = read_frame(&mut host, MAX_FRAME_PAYLOAD) {
        kinds.push(frame.kind);
        if frame.kind == MessageKind::Activate {
            break;
        }
    }
    assert!(
        kinds.contains(&MessageKind::Activate),
        "the created terminal's host never got its Activate frame, so its shell output stays \
         held for ever (frames the host read: {kinds:?})"
    );
}
