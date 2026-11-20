//! Stage S2 (DESIGN.md section 5): the router reduces a window's focus events
//! exactly as the app's focus handle does ([`WindowFocus`]): an equal topology
//! report changes nothing, and the address bar memory (Chrome's per-tab
//! omnibox focus) asks for the address bar back on a return to its tab. So one
//! reducer can own every window's focus, and the app's handle becomes the
//! router's (stage S2).

use super::support::{Session, arc, browser_tab, pane, terminal_tab, topology};
use cmux_focus_core::event::{FocusEffect, FocusEvent, Source};
use cmux_focus_core::input::{InputEffect, InputEvent};
use cmux_focus_core::omnibar_memory::return_event;
use cmux_focus_core::state::Target;
use cmux_focus_core::window::{Reduction, WindowFocus};

/// The focus effects and the reduction the router reported for `window` in
/// one call.
fn reduced(effects: &[InputEffect], window: &str) -> (Vec<FocusEffect>, Option<Reduction>) {
    let mut focus = Vec::new();
    let mut reduction = None;
    for effect in effects {
        match effect {
            InputEffect::Focus { window: of, effect } if **of == *window => {
                focus.push(effect.clone());
            }
            InputEffect::FocusReduced { window: of, reduction: r } if **of == *window => {
                reduction = Some(*r);
            }
            _ => {}
        }
    }
    (focus, reduction)
}

fn focus_pane(pane: &str, source: Source) -> FocusEvent {
    FocusEvent::FocusPane { pane: pane.into(), workspace: None, source }
}

#[test]
fn the_router_reduces_focus_events_as_the_apps_focus_handle_does() {
    let mut s = Session::new();
    s.send(InputEvent::WindowOpened { window: arc("w1") });
    let mut app = WindowFocus::new();
    let shows = topology(
        "ws",
        vec![pane("p1", vec![browser_tab("b1")]), pane("p2", vec![terminal_tab("t1", "T1")])],
    );
    let events = [
        FocusEvent::Topology { topology: shows.clone() },
        // The window reports its panes again after every daemon delta: an equal
        // topology changes nothing.
        FocusEvent::Topology { topology: shows },
        focus_pane("p1", Source::Mouse),
        FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Keyboard },
        // The person leaves the tab while its address bar has the keyboard...
        focus_pane("p2", Source::Mouse),
        // ...and comes back: the memory asks for the address bar back,
        focus_pane("p1", Source::Keyboard),
        // which the app queues after the effects: the address bar restores its
        // edit instead of selecting all.
        return_event(),
    ];
    for event in events {
        let mut want = Vec::new();
        let reduction = app.send(&event, &mut want);
        let effects = s.send(InputEvent::Focus { window: arc("w1"), event: event.clone() });
        let (got, got_reduction) = reduced(&effects, "w1");
        assert_eq!(got, want, "{event:?}");
        assert_eq!(got_reduction, Some(reduction), "{event:?}");
        assert_eq!(s.router.focus("w1"), Some(app.state()), "{event:?}");
    }
}
