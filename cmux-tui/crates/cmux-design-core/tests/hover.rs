//! Parity tests for the tooltip and hover-card rules, ported from TooltipSurfaceTests,
//! TooltipGalleryTests and the HoverCard suites, with current outputs pinned, plus the C ABI.

use cmux_design_core::ffi::*;
use cmux_design_core::hover::*;
use serde_json::{Value, json};
use std::ffi::CString;
use std::ptr::null_mut;

fn call(op: &str, request: &str) -> (i32, Option<Value>) {
    let op = CString::new(op).unwrap();
    let mut out = CmuxDesignBytes { ptr: null_mut(), len: 0 };
    let status =
        unsafe { cmux_design_call(op.as_ptr(), request.as_ptr(), request.len(), &mut out) };
    if status != CMUX_DESIGN_OK {
        return (status, None);
    }
    let reply = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    let value = serde_json::from_slice(reply).ok();
    unsafe { cmux_design_bytes_free(out) };
    (status, value)
}

fn ok(op: &str, request: Value) -> Value {
    let (status, value) = call(op, &request.to_string());
    assert_eq!(status, CMUX_DESIGN_OK, "{op} {request}");
    value.expect("reply")
}

// MARK: Tooltip surface

/// `aLowContrastThemesTooltipIsStillGlassAndReads`' raw pairs.
const PAIRS: [(u32, u32); 6] = [
    (0x002B36, 0x839496),
    (0x0A333E, 0x839496),
    (0x000000, 0x777777),
    (0x898989, 0xFFFFFF),
    (0xFDF7E7, 0x93A1A1),
    (0x808080, 0x808080),
];

#[test]
fn a_low_contrast_tooltip_is_still_glass_and_reads() {
    const { assert!(TOOLTIP_MAXIMUM_TINT_ALPHA < 1.0) };
    for (fill, ink) in PAIRS {
        let name = format!("#{fill:06X} under #{ink:06X}");
        let surface = TooltipSurface::new(Rgb::hex(fill), Rgb::hex(ink));
        let alpha = surface.tint.alpha;
        assert!(
            (TOOLTIP_MINIMUM_TINT_ALPHA..=TOOLTIP_MAXIMUM_TINT_ALPHA).contains(&alpha)
                && alpha < 1.0,
            "{name}: the tint is {alpha}, not glass"
        );
        for backdrop in [Rgb::hex(0x000000), Rgb::hex(0xFFFFFF)] {
            let contrast = surface.ink.contrast(surface.tint.composited(backdrop));
            assert!(contrast >= MINIMUM_TEXT_CONTRAST, "{name} over {backdrop:?}: {contrast}");
            let page =
                surface.ink.css_rounded().contrast(surface.tint.css_rounded().composited(backdrop));
            assert!(page >= MINIMUM_TEXT_CONTRAST, "{name} page over {backdrop:?}: {page}");
        }
        let opaque = surface.ink.contrast(surface.fill);
        assert!(opaque >= MINIMUM_TEXT_CONTRAST, "{name} opaque: {opaque}");
        let page = surface.ink.css_rounded().contrast(surface.fill.css_rounded());
        assert!(page >= MINIMUM_TEXT_CONTRAST, "{name} opaque page: {page}");
        assert_eq!(surface.fill.alpha, 1.0);
        assert!(TooltipSurface::worst_contrast(surface.ink, surface.tint) >= MINIMUM_TEXT_CONTRAST);
    }
}

#[test]
fn the_review_pairs_ink_moves_lighter_and_its_fill_is_untouched() {
    let ink = Rgb::hex(0x839496);
    let review = TooltipSurface::new(Rgb::hex(0x0A333E), ink);
    assert_eq!(review.fill, Rgb::hex(0x0A333E));
    assert!(review.ink != ink && review.ink.relative_luminance() > ink.relative_luminance());
}

#[test]
fn a_theme_whose_text_reads_keeps_its_text() {
    let surface = TooltipSurface::new(Rgb::hex(0xFFFFFF), Rgb::hex(0x000000));
    assert_eq!(surface.ink, Rgb::hex(0x000000));
    assert!(surface.tint.alpha >= TOOLTIP_MINIMUM_TINT_ALPHA);
}

#[test]
fn colours_parse_and_clamp() {
    assert_eq!(Rgb::parse_hex("#2B1650"), Some(Rgb::hex(0x2B1650)));
    assert_eq!(Rgb::parse_hex("zz"), None);
    let clamped = Rgb::new(2.0, -1.0, 0.5, 3.0);
    assert_eq!((clamped.red, clamped.green, clamped.blue, clamped.alpha), (1.0, 0.0, 0.5, 1.0));
    assert!((Rgb::BLACK.contrast(Rgb::WHITE) - 21.0).abs() < 1e-9);
}

#[test]
fn the_surface_runs_through_the_c_abi() {
    let fill = Rgb::hex(0x0A333E);
    let ink = Rgb::hex(0x839496);
    let reply = ok("hover.tooltipSurface", json!({"fill": fill, "ink": ink}));
    let native = TooltipSurface::new(fill, ink);
    let native = serde_json::to_value(native).unwrap();
    for part in ["fill", "ink", "tint"] {
        for channel in ["red", "green", "blue", "alpha"] {
            let (a, b) =
                (reply[part][channel].as_f64().unwrap(), native[part][channel].as_f64().unwrap());
            assert!((a - b).abs() < 1e-12, "{part}.{channel}: {a} vs {b}");
        }
    }
    let constants = ok("hover.tooltipSurfaceConstants", json!({}));
    assert_eq!(
        constants,
        json!({"blurRadius": 24.0, "minimumTintAlpha": 0.6, "maximumTintAlpha": 0.9,
               "minimumTextContrast": 4.5})
    );
}

// MARK: Tooltip placement

fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect::new(x, y, width, height)
}

#[test]
fn a_tooltip_sits_below_its_anchor_centered() {
    let screen = rect(0.0, 0.0, 1000.0, 800.0);
    let anchor = rect(100.0, 400.0, 40.0, 20.0);
    let origin = tooltip_origin(60.0, 24.0, anchor, screen, false);
    assert_eq!((origin.x, origin.y), (90.0, 372.0));
    let above = tooltip_origin(60.0, 24.0, anchor, screen, true);
    assert_eq!((above.x, above.y), (90.0, 424.0));
}

#[test]
fn a_tooltip_stays_inside_the_screen() {
    let screen = rect(0.0, 0.0, 1000.0, 800.0);
    // At the bottom edge it goes above.
    let low = tooltip_origin(60.0, 24.0, rect(100.0, 10.0, 40.0, 20.0), screen, false);
    assert_eq!(low.y, 34.0);
    // At the left and right edges it keeps its edge inset.
    let left = tooltip_origin(200.0, 24.0, rect(0.0, 400.0, 20.0, 20.0), screen, false);
    assert_eq!(left.x, 4.0);
    let right = tooltip_origin(200.0, 24.0, rect(990.0, 400.0, 10.0, 20.0), screen, false);
    assert_eq!(right.x, 796.0);
    // Asked above at the top edge, it stays below.
    let top = tooltip_origin(60.0, 24.0, rect(100.0, 770.0, 40.0, 20.0), screen, true);
    assert_eq!(top.y, 742.0);
    // Rounded to whole points.
    let half = tooltip_origin(61.0, 24.0, rect(100.5, 400.0, 40.0, 20.0), screen, false);
    assert_eq!(half.x, half.x.round());
}

#[test]
fn placement_and_timing_through_the_c_abi() {
    let origin = ok(
        "hover.tooltipOrigin",
        json!({"width": 60, "height": 24,
               "anchor": {"x": 100, "y": 400, "width": 40, "height": 20},
               "screen": {"x": 0, "y": 0, "width": 1000, "height": 800}}),
    );
    assert_eq!(origin, json!({"x": 90.0, "y": 372.0}));
    assert_eq!(
        ok("hover.tooltipTiming", json!({})),
        json!({"panelMargin": 3.0, "recheckMs": 500, "scrollQuietMs": 150})
    );
    let metrics = ok("hover.tooltipMetrics", json!({}));
    assert_eq!(metrics["maxWidth"], json!(320.0));
    assert_eq!(metrics["keycapRadius"], json!(4.0));
}

// MARK: Gallery

#[test]
fn the_gallery_samples_and_columns_are_pinned() {
    let names: Vec<&str> = TOOLTIP_GALLERY_SAMPLES.iter().map(|s| s.name).collect();
    assert_eq!(
        names,
        [
            "Text only",
            "With a shortcut",
            "Several keys",
            "Too long for 320 pt",
            "Too long, with a shortcut",
            "Reduce Transparency"
        ]
    );
    let shortcuts: Vec<Option<&str>> = TOOLTIP_GALLERY_SAMPLES.iter().map(|s| s.shortcut).collect();
    assert_eq!(shortcuts, [None, Some("⌘T"), Some("⌃⇧M"), None, Some("⌥⌘N"), Some("⌘T")]);
    assert_eq!(TOOLTIP_GALLERY_SAMPLES.iter().filter(|s| s.opaque).count(), 1);
    assert!(TOOLTIP_GALLERY_SAMPLES[3].text.len() > 60);

    let columns = tooltip_gallery_columns();
    assert_eq!(columns.iter().map(|c| c.title).collect::<Vec<_>>(), ["Light", "Dark", "Accent"]);
    assert_eq!(columns.iter().map(|c| c.is_dark).collect::<Vec<_>>(), [false, true, true]);
    assert_eq!(columns[2].spec, Some(ACCENT_SPEC));
    assert_eq!(columns[2].background, Some(Rgb::hex(0x2B1650)));
    assert_eq!(columns[2].foreground, Some(Rgb::hex(0xF4E3FF)));

    let window = ok("hover.galleryWindow", json!({}));
    assert_eq!(window["title"], json!("Tooltip Gallery"));
    assert_eq!(window["accessibilityIdentifier"], json!("cmux.tooltipGallery"));
    assert_eq!(window["frame"]["width"], json!(1180.0));
    assert_eq!(ok("hover.gallerySamples", json!({})).as_array().unwrap().len(), 6);
    assert_eq!(ok("hover.galleryColumns", json!({}))[2]["theme"], json!("accent"));
}

// MARK: Hover cards

#[test]
fn entrances_and_retargets_are_pinned() {
    assert_eq!(
        ok("hover.entrances", json!({})),
        json!([
            {"rawValue": "fade", "title": "Fade"},
            {"rawValue": "slide", "title": "Fade and slide"},
            {"rawValue": "morph", "title": "Grow out of the tab"},
        ])
    );
    assert_eq!(
        ok("hover.retargets", json!({})),
        json!([
            {"rawValue": "jump", "title": "Switch in place"},
            {"rawValue": "crossfade", "title": "Switch in place, crossfade content"},
            {"rawValue": "glide", "title": "Glide to the next tab"},
        ])
    );
    assert_eq!(HoverCardEntrance::ALL.len(), 3);
    assert_eq!(HoverCardRetarget::ALL.len(), 3);
}

#[test]
fn the_card_style_is_pinned() {
    let style = ok("hover.cardStyle", json!({}));
    assert_eq!(style["padding"], json!(16.0));
    assert_eq!(style["titleGap"], json!(8.0));
    assert_eq!(style["rowGap"], json!(8.0));
    assert_eq!(style["mediaGap"], json!(16.0));
    assert_eq!(SIDEBAR_GROUP, "sidebar");
}

#[test]
fn the_present_note_reads_as_the_debug_line() {
    let note =
        HoverCardPresentNote { on_screen: true, glides: true, morphed: true, ..Default::default() };
    assert_eq!(
        note.text(),
        "on_screen=true glides=true sweeping=false fades_bodies=false same_body=false moves=false \
         live_resize=false in_place=false morphed=true"
    );
    assert_eq!(
        ok("hover.presentNote", json!({"note": {"inPlace": true}})),
        json!(
            "on_screen=false glides=false sweeping=false fades_bodies=false same_body=false \
             moves=false live_resize=false in_place=true morphed=false"
        )
    );
}

#[test]
fn the_card_takes_the_mouse_only_under_the_pointer() {
    // An owner's card and a card that takes no clicks are left alone.
    assert_eq!(card_ignores_mouse(true, true, true, true, true, true), None);
    assert_eq!(card_ignores_mouse(false, false, true, true, true, true), None);
    // Shown, showing and under the pointer: it takes the mouse.
    assert_eq!(card_ignores_mouse(false, true, true, true, true, true), Some(false));
    assert_eq!(card_ignores_mouse(false, true, true, true, true, false), None);
    // Anything else: it ignores the mouse.
    assert_eq!(card_ignores_mouse(false, true, true, true, false, false), Some(true));
    assert_eq!(card_ignores_mouse(false, true, false, true, true, false), Some(true));
    assert_eq!(card_ignores_mouse(false, true, true, false, true, true), None);
    assert_eq!(
        ok(
            "hover.cardMouse",
            json!({"interactive": true, "shown": true, "showingCard": true,
            "pointerOnCard": false, "ignoresNow": false})
        ),
        json!(true)
    );
}

fn event(kind: MonitoredEventType) -> MonitoredEvent {
    MonitoredEvent { kind: Some(kind), ..Default::default() }
}

#[test]
fn the_monitor_keeps_the_card_for_its_own_events_and_dismisses_on_the_rest() {
    use MonitoredEventType::*;
    let card = MonitoredEvent {
        interactive: true,
        showing_card: true,
        shown: true,
        belongs_to_parent: true,
        pointer_on_card: true,
        point_on_card: true,
        body_took_key: true,
        body_accepts_mouse: true,
        kind: None,
    };
    assert_eq!(
        monitored_event(MonitoredEvent { kind: Some(KeyDown), ..card }),
        MonitoredOutcome::KeyTaken
    );
    assert_eq!(
        monitored_event(MonitoredEvent { kind: Some(LeftMouseDown), ..card }),
        MonitoredOutcome::DeliverToCard
    );
    assert_eq!(
        monitored_event(MonitoredEvent { kind: Some(ScrollWheel), ..card }),
        MonitoredOutcome::ScrollCard
    );
    // A key the body did not take dismisses.
    assert_eq!(
        monitored_event(MonitoredEvent { kind: Some(KeyDown), body_took_key: false, ..card }),
        MonitoredOutcome::Dismiss { reason: HoverDismissal::KeyDown }
    );
    // A right click on the card dismisses as a click.
    assert_eq!(
        monitored_event(MonitoredEvent { kind: Some(RightMouseDown), ..card }),
        MonitoredOutcome::Dismiss { reason: HoverDismissal::Click }
    );
    // A non-interactive card still scrolls under the pointer.
    assert_eq!(
        monitored_event(MonitoredEvent { kind: Some(ScrollWheel), interactive: false, ..card }),
        MonitoredOutcome::ScrollCard
    );
    assert_eq!(
        monitored_event(event(ScrollWheel)),
        MonitoredOutcome::Dismiss { reason: HoverDismissal::ScrollWheel }
    );
    assert_eq!(
        monitored_event(event(OtherMouseDown)),
        MonitoredOutcome::Dismiss { reason: HoverDismissal::Click }
    );
    assert_eq!(
        ok("hover.monitoredEvent", json!({"type": "keyDown"})),
        json!({"outcome": "dismiss", "reason": "keyDown"})
    );
    let (status, _) = call("hover.monitoredEvent", "{}");
    assert_ne!(status, CMUX_DESIGN_OK);
    let (status, _) = call("hover.nope", "{}");
    assert_ne!(status, CMUX_DESIGN_OK);
}
