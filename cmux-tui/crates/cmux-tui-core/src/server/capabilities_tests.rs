use super::*;
use crate::{SurfaceOptions, start_terminal_reaper};

/// A client decides from `identify` whether closing a tab may only
/// detach its terminal: that is safe only while the reaper runs.
#[test]
fn identify_advertises_the_reaper_only_while_it_runs() {
    let mux = Mux::new_for_test("reaper-capability", SurfaceOptions::default());
    assert!(identify_capabilities(&mux).contains(&TERMINAL_REAP_CAPABILITY));
    assert!(!identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY));
    let reaper = start_terminal_reaper(&mux).unwrap();
    assert!(identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY));
    reaper.stop();
    assert!(!identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY));
    assert!(identify_capabilities(&mux).contains(&TERMINAL_REAP_CAPABILITY));
}

/// The server answers `identify` from its attach, and the owner started
/// its reaper only later: a client that identified in between saw an
/// owner without a reaper (main #39586 on macOS). An owner that announced
/// its reaper lists the capability from the start; a stopped reaper ends
/// the announcement.
#[test]
fn identify_lists_an_announced_reaper_before_it_starts() {
    let mux = Mux::new_for_test("reaper-announced", SurfaceOptions::default());
    mux.announce_terminal_reaper();
    assert!(
        identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY),
        "an owner that starts its reaper after its attach answered identify without \
             terminal-reaper-active-v1 before the reaper thread ran"
    );
    let reaper = start_terminal_reaper(&mux).unwrap();
    assert!(identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY));
    reaper.stop();
    assert!(
        !identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY),
        "a stopped reaper is still advertised"
    );
}

/// `cmux-tui capabilities` names only what `identify` always serves: a
/// daemon with nothing installed at startup advertises every one of them.
#[test]
fn identify_serves_every_static_capability() {
    let mux = Mux::new_for_test("static-capabilities", SurfaceOptions::default());
    let identified = identify_capabilities(&mux);
    let listed = static_capabilities();
    assert!(listed.contains(&conversations::WS_CONVERSATIONS_CAPABILITY));
    assert!(listed.contains(&page_credential::PAGE_CREDENTIAL_CAPABILITY));
    for capability in &listed {
        assert!(identified.contains(capability), "identify lacks {capability}");
    }
    assert!(listed.windows(2).all(|pair| pair[0] < pair[1]), "sorted and unique: {listed:?}");
    assert!(!listed.contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY), "runtime-only");
    assert!(listed.contains(&TERMINAL_CLOSE_IF_UNPLACED_CAPABILITY), "static");
}
