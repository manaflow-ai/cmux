//! A `tab-changed` delta reports the tab as it is when the delta goes out.
//! Its decorations (git lookups for every tab) take a while; a pin that
//! commits meanwhile must be in the delta, or the app applies the stale
//! `pinned: false` after the pin's own tree resync and the tab shows
//! unpinned until something else touches it (PinnedPageTests on the fleet,
//! #20123's report: the pin was sent and succeeded, the store stayed false).

use std::sync::{Arc, Mutex, mpsc};

use serde_json::json;

use super::tests::{mutate, tab_id, terminal_tabs};
use crate::mux::*;
use crate::surface::SurfaceOptions;

#[test]
fn a_tab_changed_delta_in_flight_during_a_pin_reports_the_tab_pinned() {
    let mux = Mux::new_for_test("tab-changed-pin", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let surface = tabs[1];
    let tab = tab_id(&mux, surface);

    // The first tab-changed emit parks after its decorations are read.
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel::<()>();
    let release_rx = Arc::new(Mutex::new(release_rx));
    let parked = Arc::new(std::sync::atomic::AtomicBool::new(false));
    mux.set_tab_changed_after_decorations(Some(Arc::new({
        let parked = Arc::clone(&parked);
        move || {
            if !parked.swap(true, std::sync::atomic::Ordering::SeqCst) {
                entered_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }
    })));
    let events = mux.subscribe();
    let emitting = {
        let mux = Arc::clone(&mux);
        std::thread::spawn(move || mux.emit_tab_changed(surface))
    };
    entered_rx.recv().unwrap();

    mutate(&mux, "tab.pin", json!({"tab": tab}), "pin-while-a-delta-is-in-flight");
    release_tx.send(()).unwrap();
    emitting.join().unwrap();
    mux.set_tab_changed_after_decorations(None);

    let mut last = None;
    while let Ok(event) = events.try_recv() {
        if let MuxEvent::TreeDelta(delta) = event
            && matches!(delta.kind, TreeDeltaKind::TabChanged)
            && delta.surface == Some(surface)
        {
            last = Some(delta.entity);
        }
    }
    let last = last.expect("no tab-changed delta for the tab");
    assert_eq!(
        last["pinned"],
        json!(true),
        "the last tab-changed delta has the tab unpinned: {last}"
    );
}
