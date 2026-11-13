//! A terminal no render viewer watches builds no render frame for a viewport
//! scroll, a resize, a history clear or new default colors; the next attach
//! builds one frame with all of them.

use super::*;

#[test]
fn unviewed_terminal_builds_no_frame_until_a_render_viewer_attaches() {
    let mux = Mux::new_for_test("unviewed-frames", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let output: String = (1..=300).map(|line| format!("line {line}\r\n")).collect();
    surface.with_terminal(|term| term.vt_write(output.as_bytes()));
    let built = || pty.render.lock().unwrap().built_generation;
    let before = built();

    surface.scroll_delta(-3).unwrap();
    assert_eq!(built(), before, "a viewport scroll built a frame no viewer reads");
    surface.scroll_to_bottom().unwrap();
    assert_eq!(built(), before, "scroll to bottom built a frame no viewer reads");
    surface.resize(61, 11).unwrap();
    assert_eq!(built(), before, "a resize built a frame no viewer reads");
    let background = Rgb { r: 0x12, g: 0x34, b: 0x56 };
    let foreground = Rgb { r: 0xee, g: 0xdd, b: 0xcc };
    surface.set_default_colors(DefaultColors {
        fg: Some(foreground),
        bg: Some(background),
        ..DefaultColors::default()
    });
    assert_eq!(built(), before, "new default colors built a frame no viewer reads");
    surface.clear_history().unwrap();
    assert_eq!(built(), before, "a history clear built a frame no viewer reads");

    surface.with_terminal(|term| term.vt_write(output.as_bytes()));
    surface.scroll_delta(-2).unwrap();
    let scrolled = surface.with_terminal(|term| term.scrollbar()).flatten().unwrap();
    let generation = pty.render_generation.load(Ordering::Acquire);
    let attach = surface.attach_render_stream().unwrap();
    assert!(attach.initial.content_generation >= generation, "attach served an old frame");
    assert_eq!(attach.initial.frame.size, (61, 11));
    assert_eq!(attach.initial.frame.default_colors, (background, foreground));
    assert!(
        matches!(attach.stream.try_recv(), Ok(RenderAttachFrame::ScrollChanged { offset, at_bottom: false })
            if offset == scrolled.offset),
        "the attach must learn the scrolled-back viewport first"
    );

    // With a viewer, the same changes build their frames at once.
    let viewed = built();
    surface.scroll_delta(-1).unwrap();
    assert!(built() > viewed, "a viewed terminal's scroll must build its frame");
}
