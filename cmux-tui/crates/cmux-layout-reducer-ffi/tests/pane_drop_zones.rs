//! The C ABI of the pane drop zones (`cmux_pane_drop_*`): a screen handle answers the Swift rule's cases
//! (DropZoneRuleTests) through the C calls, the structs have the header's layout, and null pointers write
//! nothing.

use cmux_layout_reducer_ffi::ERR_NULL;
use cmux_layout_reducer_ffi::pane_drop_zones::{
    CmuxPaneDropRect, CmuxPaneDropRects, CmuxPaneDropTarget, KIND_COLUMN, KIND_DOCK, KIND_NONE,
    KIND_PANE, PaneDropScreen, cmux_pane_drop_classic_highlight, cmux_pane_drop_dock,
    cmux_pane_drop_rects, cmux_pane_drop_screen_free, cmux_pane_drop_screen_new,
    cmux_pane_drop_target, cmux_pane_drop_target_in_content, cmux_pane_drop_zone,
};
use cmux_layout_reducer_ffi::tab_drag::{
    EDGE_BOTTOM, EDGE_LEFT, EDGE_TOP, ZONE_CENTER, ZONE_LEFT, ZONE_RIGHT,
};
use std::ptr;

const HEADER: &str = include_str!("../include/cmux_layout_reducer_ffi.h");

const SCREEN: &str = r#"{"width": 1200, "height": 800,
  "panes": [{"rect": {"x": 0, "y": 0, "width": 1200, "height": 800}}],
  "gaps": [{"x": 282, "y": 0, "width": 36, "height": 800}],
  "stripMinX": 0}"#;

struct Screen(*mut PaneDropScreen);

impl Screen {
    fn new(json: &str) -> Self {
        // SAFETY: the bytes are live for the call.
        let screen = unsafe { cmux_pane_drop_screen_new(json.as_ptr(), json.len()) };
        assert!(!screen.is_null(), "screen parses");
        Self(screen)
    }
    fn target(
        &self,
        x: f64,
        y: f64,
        offset: f64,
        previous: Option<CmuxPaneDropTarget>,
    ) -> Option<CmuxPaneDropTarget> {
        let mut out = CmuxPaneDropTarget::default();
        let previous = previous.as_ref().map_or(ptr::null(), ptr::from_ref);
        // SAFETY: a live handle and live pointers.
        match unsafe { cmux_pane_drop_target(self.0, x, y, offset, previous, &mut out) } {
            1 => Some(out),
            0 => None,
            code => panic!("target failed: {code}"),
        }
    }
    fn dock(
        &self,
        x: f64,
        y: f64,
        previous: Option<CmuxPaneDropTarget>,
    ) -> Option<CmuxPaneDropTarget> {
        let mut out = CmuxPaneDropTarget::default();
        let previous = previous.as_ref().map_or(ptr::null(), ptr::from_ref);
        // SAFETY: a live handle and live pointers.
        match unsafe { cmux_pane_drop_dock(self.0, x, y, 30.0, 20.0, previous, &mut out) } {
            1 => Some(out),
            0 => None,
            code => panic!("dock failed: {code}"),
        }
    }
}

impl Drop for Screen {
    fn drop(&mut self) {
        // SAFETY: freed once.
        unsafe { cmux_pane_drop_screen_free(self.0) };
    }
}

fn target(kind: u8, index: u32, zone: u8) -> CmuxPaneDropTarget {
    CmuxPaneDropTarget { index, kind, zone, reserved: [0; 2] }
}

fn pane(zone: u8) -> CmuxPaneDropTarget {
    target(KIND_PANE, 0, zone)
}

fn gap() -> CmuxPaneDropTarget {
    target(KIND_COLUMN, 0, ZONE_CENTER)
}

fn dock(edge: u8) -> CmuxPaneDropTarget {
    target(KIND_DOCK, 0, edge)
}

#[test]
fn a_screen_handle_answers_the_rule() {
    let screen = Screen::new(SCREEN);
    for offset in [0.0, 75.0] {
        assert_eq!(screen.target(600.0 - offset, 400.0, offset, None), Some(pane(ZONE_CENTER)));
        assert_eq!(screen.target(283.0 - offset, 400.0, offset, None), Some(gap()));
        assert_eq!(screen.target(281.0 - offset, 400.0, offset, None), Some(pane(ZONE_LEFT)));
        assert_eq!(screen.target(329.0 - offset, 400.0, offset, Some(gap())), Some(gap()));
        assert_eq!(
            screen.target(286.0 - offset, 400.0, offset, Some(pane(ZONE_RIGHT))),
            Some(pane(ZONE_LEFT))
        );
        // Another screen's pane and an empty previous count as no shown target.
        let other = target(KIND_PANE, u32::MAX, ZONE_LEFT);
        assert_eq!(
            screen.target(283.0 - offset, 400.0, offset, Some(other)),
            Some(pane(ZONE_LEFT))
        );
        assert_eq!(
            screen.target(283.0 - offset, 400.0, offset, Some(target(KIND_NONE, 0, 0))),
            Some(gap())
        );
    }
    let mut out = CmuxPaneDropTarget::default();
    // SAFETY: a live handle and live pointers.
    assert_eq!(
        unsafe { cmux_pane_drop_target_in_content(screen.0, 283.0, 400.0, ptr::null(), &mut out) },
        1
    );
    assert_eq!(out, gap());
    assert_eq!(screen.dock(600.0, 74.0, Some(dock(EDGE_TOP))), Some(dock(EDGE_TOP)));
    assert_eq!(screen.dock(600.0, 74.0, None), None);
    assert_eq!(screen.dock(600.0, 769.0, Some(pane(3))), Some(dock(EDGE_BOTTOM)));
    assert_eq!(screen.dock(9.0, 400.0, Some(pane(ZONE_LEFT))), None);
    assert_eq!(screen.dock(5.0, 400.0, Some(pane(ZONE_LEFT))), Some(dock(EDGE_LEFT)));
}

#[test]
fn rects_cross_in_view_space() {
    let screen = Screen::new(SCREEN);
    let mut out = CmuxPaneDropRects::default();
    // SAFETY: a live handle and live pointers.
    assert_eq!(unsafe { cmux_pane_drop_rects(screen.0, &pane(ZONE_RIGHT), 100.0, &mut out) }, 1);
    assert_eq!(out.highlight, CmuxPaneDropRect { x: 500.0, y: 0.0, width: 600.0, height: 800.0 });
    assert_eq!(out.region, CmuxPaneDropRect { x: -100.0, y: 0.0, width: 1200.0, height: 800.0 });
    assert_eq!((out.has_body, out.body), (1, out.region));
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_pane_drop_rects(screen.0, &gap(), 100.0, &mut out) }, 1);
    assert_eq!((out.has_body, out.region.x), (0, 182.0));
    // SAFETY: as above.
    assert_eq!(
        unsafe { cmux_pane_drop_rects(screen.0, &target(KIND_PANE, 4, ZONE_LEFT), 0.0, &mut out) },
        0
    );
}

#[test]
fn classic_highlight_is_the_inset_half() {
    let body = CmuxPaneDropRect { x: 0.0, y: 0.0, width: 400.0, height: 200.0 };
    let mut out = CmuxPaneDropRect::default();
    // SAFETY: a live pointer.
    assert_eq!(unsafe { cmux_pane_drop_classic_highlight(body, ZONE_LEFT, 4.0, &mut out) }, 1);
    assert_eq!(out, CmuxPaneDropRect { x: 4.0, y: 4.0, width: 196.0, height: 192.0 });
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_pane_drop_classic_highlight(body, 9, 4.0, &mut out) }, 0);
}

#[test]
fn zone_reads_the_screen_style() {
    let screen = Screen::new(SCREEN);
    let cell = CmuxPaneDropRect { x: 0.0, y: 0.0, width: 400.0, height: 300.0 };
    let zone = |x: f64, y: f64, previous: u8| {
        let mut out = u8::MAX;
        // SAFETY: a live handle and pointer.
        assert_eq!(
            unsafe { cmux_pane_drop_zone(screen.0, x, y, cell, 30.0, 0.0, previous, &mut out) },
            1
        );
        out
    };
    assert_eq!(zone(10.0, 150.0, u8::MAX), ZONE_LEFT);
    assert_eq!(zone(200.0, 10.0, u8::MAX), ZONE_CENTER, "over the tab bar a tab joins");
    assert_eq!(zone(105.0, 165.0, u8::MAX), ZONE_CENTER);
    assert_eq!(zone(105.0, 165.0, ZONE_LEFT), ZONE_LEFT, "the shown zone holds past its line");
    let mut out = 0;
    // SAFETY: null pointers are part of the contract.
    assert_eq!(
        unsafe { cmux_pane_drop_zone(ptr::null(), 0.0, 0.0, cell, 0.0, 0.0, 0, &mut out) },
        ERR_NULL
    );
}

#[test]
fn null_and_bad_input_write_nothing() {
    let bad = b"{";
    // SAFETY: live bytes; null pointers are part of the contract.
    unsafe {
        assert!(cmux_pane_drop_screen_new(bad.as_ptr(), bad.len()).is_null());
        assert!(cmux_pane_drop_screen_new(ptr::null(), 4).is_null());
        let mut out = CmuxPaneDropTarget::default();
        assert_eq!(
            cmux_pane_drop_target(ptr::null(), 0.0, 0.0, 0.0, ptr::null(), &mut out),
            ERR_NULL
        );
        assert_eq!(
            cmux_pane_drop_dock(ptr::null(), 0.0, 0.0, 0.0, 0.0, ptr::null(), &mut out),
            ERR_NULL
        );
        assert_eq!(
            cmux_pane_drop_classic_highlight(CmuxPaneDropRect::default(), 0, 4.0, ptr::null_mut()),
            ERR_NULL
        );
        cmux_pane_drop_screen_free(ptr::null_mut());
    }
    let empty = Screen::new("{}");
    assert_eq!(empty.target(1.0, 1.0, 0.0, None), None);
}

#[test]
fn structs_and_kinds_match_the_header() {
    use std::mem::{align_of, size_of};
    assert_eq!((size_of::<CmuxPaneDropTarget>(), align_of::<CmuxPaneDropTarget>()), (8, 4));
    assert_eq!((size_of::<CmuxPaneDropRect>(), align_of::<CmuxPaneDropRect>()), (32, 8));
    assert_eq!((size_of::<CmuxPaneDropRects>(), align_of::<CmuxPaneDropRects>()), (3 * 32 + 8, 8));
    for (name, value) in
        [("NONE", KIND_NONE), ("PANE", KIND_PANE), ("COLUMN", KIND_COLUMN), ("DOCK", KIND_DOCK)]
    {
        assert!(HEADER.contains(&format!("CMUX_PANE_DROP_KIND_{name} = {value},")), "{name}");
    }
    for symbol in [
        "cmux_pane_drop_screen_new",
        "cmux_pane_drop_screen_free",
        "cmux_pane_drop_target",
        "cmux_pane_drop_target_in_content",
        "cmux_pane_drop_dock",
        "cmux_pane_drop_rects",
        "cmux_pane_drop_classic_highlight",
        "cmux_pane_drop_zone",
    ] {
        assert!(HEADER.contains(&format!("{symbol}(")), "{symbol}");
    }
}
