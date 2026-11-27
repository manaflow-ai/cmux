use super::{readback_plan, Capturer, Rect};

/// A change another connection has already been told about is in the next take, though
/// this connection read no event for it (review of cmux#47241: a drain of queued raw
/// events missed the newest change the gate had released, and it stayed unsent).
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn a_take_holds_every_change_the_loop_connection_has_seen() {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{ConnectionExt as _, CreateGCAux, Rectangle};
    let xvfb = crate::inject::tests::Xvfb::start();
    let mut cap = Capturer::with_region(&xvfb.display).unwrap();
    let loop_conn = Capturer::new(&xvfb.display, true).unwrap();
    let mut first = Vec::new();
    cap.take_damage(&mut first).unwrap();
    let (draw, screen) = x11rb::connect(Some(&xvfb.display)).unwrap();
    let root = draw.setup().roots[screen].root;
    let gc = draw.generate_id().unwrap();
    draw.create_gc(gc, root, &CreateGCAux::new().foreground(0xff_ff_ff)).unwrap();
    for (x, y) in [(0, 0), (1000, 700)] {
        let r = Rectangle { x, y, width: 8, height: 16 };
        draw.poly_fill_rectangle(root, gc, &[r]).unwrap();
    }
    draw.get_input_focus().unwrap().reply().unwrap();
    // The loop connection has both changes (its own round trip, then its queue).
    loop_conn.conn.get_input_focus().unwrap().reply().unwrap();
    let mut seen = Vec::new();
    loop_conn.drain(&mut seen, &mut Vec::new()).unwrap();
    assert!(seen.iter().any(|e| e.rect.x >= 1000), "the loop never saw the second change");
    let mut taken = Vec::new();
    cap.take_damage(&mut taken).unwrap();
    for (x, y) in [(0, 0), (1000, 700)] {
        let held =
            taken.iter().any(|r| r.x <= x && r.y <= y && r.x + r.w >= x + 8 && r.y + r.h >= y + 16);
        assert!(held, "the change at {x},{y} is not in the take: {taken:?}");
    }
    let mut again = Vec::new();
    cap.take_damage(&mut again).unwrap();
    assert!(again.is_empty(), "a take clears what it returned: {again:?}");
}

fn r(x: u32, y: u32, w: u32, h: u32) -> Rect {
    Rect { x, y, w, h }
}

/// Two glyphs at opposite corners of 1080p are two glyph readbacks, not the 1904x1064 box
/// between them (8 MB read back and converted for 1 KB of change).
#[test]
fn far_apart_changes_are_read_back_one_by_one() {
    let plan = readback_plan(&[r(0, 0, 8, 16), r(1912, 1064, 8, 16)], 1920, 1080);
    assert_eq!(plan, vec![r(0, 0, 8, 16), r(1912, 1064, 8, 16)]);
}

/// Pieces that cover most of their box go as the one box.
#[test]
fn close_changes_go_as_their_bounding_box() {
    let plan = readback_plan(&[r(0, 0, 100, 100), r(100, 0, 100, 100)], 1920, 1080);
    assert_eq!(plan, vec![r(0, 0, 200, 100)]);
}

/// Many small pieces fall back to one box, so a frame never makes hundreds of requests.
#[test]
fn many_pieces_fall_back_to_the_box() {
    let damage: Vec<Rect> = (0..20).map(|i| r(i * 90, i * 50, 2, 2)).collect();
    assert_eq!(readback_plan(&damage, 1920, 1080), vec![r(0, 0, 1712, 952)]);
}

/// Odd edges grow to even (4:2:0 chroma), empty and off-screen rects drop out.
#[test]
fn rects_are_even_aligned_and_empty_ones_dropped() {
    let plan = readback_plan(&[r(3, 5, 3, 3), r(10, 10, 0, 4), r(2000, 0, 4, 4)], 1920, 1080);
    assert_eq!(plan, vec![r(2, 4, 4, 4)]);
    assert!(readback_plan(&[], 1920, 1080).is_empty());
}
