use super::*;

#[test]
fn messages_have_their_wire_layout() {
    assert_eq!(key_event(0xff0d, true), [4, 1, 0, 0, 0, 0, 0xff, 0x0d]);
    assert_eq!(pointer_event(button::LEFT, 300, 2), [5, 1, 1, 44, 0, 2]);
    assert_eq!(
        update_request(true, &Rect::new(0, 0, 640, 480)),
        [3, 1, 0, 0, 0, 0, 2, 128, 1, 224]
    );
    assert_eq!(set_encodings(&[16, -239]), [2, 0, 0, 2, 0, 0, 0, 16, 0xff, 0xff, 0xff, 0x11]);
    assert_eq!(client_cut_text(b"hi"), [6, 0, 0, 0, 0, 0, 0, 2, b'h', b'i']);
    let resize = set_desktop_size(1280, 800, 7);
    assert_eq!(resize.len(), 8 + 16);
    assert_eq!(&resize[..8], &[251, 0, 5, 0, 3, 32, 1, 0]);
    assert_eq!(&resize[8..12], &7u32.to_be_bytes());
    assert_eq!(set_pixel_format(&PixelFormat::RGBX).len(), 20);
}
