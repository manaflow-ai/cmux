//! Client-to-server messages (RFC 6143 7.5 and the SetDesktopSize extension).

use crate::framebuffer::Rect;
use crate::pixel::PixelFormat;

/// Pointer button bits of a PointerEvent.
pub mod button {
    pub const LEFT: u8 = 1;
    pub const MIDDLE: u8 = 2;
    pub const RIGHT: u8 = 4;
    pub const WHEEL_UP: u8 = 8;
    pub const WHEEL_DOWN: u8 = 16;
    pub const WHEEL_LEFT: u8 = 32;
    pub const WHEEL_RIGHT: u8 = 64;
}

/// One screen of an ExtendedDesktopSize layout.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Screen {
    pub id: u32,
    pub rect: Rect,
    pub flags: u32,
}

pub fn set_pixel_format(format: &PixelFormat) -> Vec<u8> {
    let mut out = vec![0, 0, 0, 0];
    out.extend_from_slice(&format.encode());
    out
}

pub fn set_encodings(encodings: &[i32]) -> Vec<u8> {
    let mut out = vec![2, 0];
    out.extend_from_slice(&(encodings.len() as u16).to_be_bytes());
    for encoding in encodings {
        out.extend_from_slice(&encoding.to_be_bytes());
    }
    out
}

pub fn update_request(incremental: bool, rect: &Rect) -> Vec<u8> {
    let mut out = vec![3, u8::from(incremental)];
    for value in [rect.x, rect.y, rect.width, rect.height] {
        out.extend_from_slice(&value.to_be_bytes());
    }
    out
}

pub fn key_event(keysym: u32, down: bool) -> Vec<u8> {
    let mut out = vec![4, u8::from(down), 0, 0];
    out.extend_from_slice(&keysym.to_be_bytes());
    out
}

pub fn pointer_event(buttons: u8, x: u16, y: u16) -> Vec<u8> {
    let mut out = vec![5, buttons];
    out.extend_from_slice(&x.to_be_bytes());
    out.extend_from_slice(&y.to_be_bytes());
    out
}

pub fn client_cut_text(latin1: &[u8]) -> Vec<u8> {
    let mut out = vec![6, 0, 0, 0];
    out.extend_from_slice(&(latin1.len() as u32).to_be_bytes());
    out.extend_from_slice(latin1);
    out
}

/// SetDesktopSize (251) with one screen covering the new size; the screen
/// keeps the server's id so a multi-head layout collapses to its first head.
pub fn set_desktop_size(width: u16, height: u16, screen_id: u32) -> Vec<u8> {
    let mut out = vec![251, 0];
    out.extend_from_slice(&width.to_be_bytes());
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(&[1, 0]);
    out.extend_from_slice(&screen_id.to_be_bytes());
    out.extend_from_slice(&[0, 0, 0, 0]);
    out.extend_from_slice(&width.to_be_bytes());
    out.extend_from_slice(&height.to_be_bytes());
    out.extend_from_slice(&0u32.to_be_bytes());
    out
}

#[cfg(test)]
mod tests {
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
}
