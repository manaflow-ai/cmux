use super::*;
use crate::inject::tests::Xvfb;
use x11rb::protocol::xproto::{ConnectionExt as _, CreateGCAux, Rectangle, Window};

/// Paints the top-left `w`x`h` of `root` white (Xvfb's root starts black, the same as a
/// fresh segment's zeros) and returns once the server has drawn it.
fn paint_white(conn: &impl Connection, root: Window, (w, h): (u16, u16)) {
    let gc = conn.generate_id().unwrap();
    conn.create_gc(gc, root, &CreateGCAux::new().foreground(0xff_ff_ff)).unwrap();
    conn.poly_fill_rectangle(root, gc, &[Rectangle { x: 0, y: 0, width: w, height: h }]).unwrap();
    conn.get_input_focus().unwrap().reply().unwrap();
}

fn all_pixels(bytes: &[u8], bgr: [u8; 3]) -> bool {
    bytes.chunks_exact(4).all(|px| px[..3] == bgr)
}

/// What `get_image` returns is what the server wrote, after it wrote it.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn get_image_returns_what_the_server_wrote() {
    let xvfb = Xvfb::start();
    let (conn, screen) = x11rb::connect(Some(&xvfb.display)).unwrap();
    let root = conn.setup().roots[screen].root;
    paint_white(&conn, root, (64, 64));
    let mut seg = ShmSeg::new(&conn, 64 * 64 * 4, ServerAccess::ReadWrite).unwrap();
    let pixels = seg.get_image(&conn, root, (0, 0), (64, 64)).unwrap();
    assert_eq!(pixels.len(), 64 * 64 * 4);
    assert!(all_pixels(pixels, [0xff; 3]), "the white rectangle did not come back");
    assert!(seg.get_image(&conn, root, (0, 0), (65, 64)).is_err(), "past the segment");
}

/// A segment that is only put from is read-only to the server: a request that would
/// write it is refused, so its pages change only through `pixels_mut`. Putting from it
/// still works.
#[test]
#[ignore = "needs Xvfb; run with --ignored on a Linux host"]
fn a_read_only_segment_is_never_written_by_the_server() {
    let xvfb = Xvfb::start();
    let (conn, screen) = x11rb::connect(Some(&xvfb.display)).unwrap();
    let root = conn.setup().roots[screen].root;
    paint_white(&conn, root, (64, 64));
    let mut seg = ShmSeg::new(&conn, 64 * 64 * 4, ServerAccess::Read).unwrap();
    let refused = conn
        .shm_get_image(root, 0, 0, 64, 64, !0, ImageFormat::Z_PIXMAP.into(), seg.seg, 0)
        .unwrap()
        .reply();
    assert!(refused.is_err(), "the server wrote a read-only segment");
    assert!(seg.pixels_mut().iter().all(|&b| b == 0), "its pages changed");
    // Red (BGRX) put from it reaches the root.
    for px in seg.pixels_mut().chunks_exact_mut(4) {
        px.copy_from_slice(&[0, 0, 0xff, 0]);
    }
    let gc = conn.generate_id().unwrap();
    conn.create_gc(gc, root, &CreateGCAux::new()).unwrap();
    seg.put_image(&conn, root, gc, (64, 64), 24).unwrap();
    let mut back = ShmSeg::new(&conn, 64 * 64 * 4, ServerAccess::ReadWrite).unwrap();
    let pixels = back.get_image(&conn, root, (0, 0), (64, 64)).unwrap();
    assert!(all_pixels(pixels, [0, 0, 0xff]), "the put did not reach the root");
}
