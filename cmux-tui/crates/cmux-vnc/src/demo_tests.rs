//! Parity with the Swift DemoConnection's handshake, message reads and
//! rectangle bytes.
use super::*;

fn config(password: Option<&str>) -> Config {
    Config { width: 320, height: 200, name: "cmux demo".into(), password: password.map(Into::into) }
}

const CHALLENGE: [u8; 16] = [7; 16];

fn to_normal(c: &mut Connection, cfg: &Config) {
    let step = receive(c, b"RFB 003.008\n\x01\x01", cfg, CHALLENGE);
    assert_eq!(step.consumed, 14);
    assert_eq!(c.phase, Phase::Normal);
}

#[test]
fn the_handshake_without_a_password() {
    let cfg = config(None);
    let mut c = Connection::default();
    let step = receive(&mut c, b"RFB 003.0", &cfg, CHALLENGE);
    assert_eq!((step.consumed, step.reply.len()), (0, 0), "waits for the whole banner");
    let step = receive(&mut c, b"RFB 003.008\n", &cfg, CHALLENGE);
    assert_eq!(step.reply, [1, 1]);
    let step = receive(&mut c, &[1], &cfg, CHALLENGE);
    assert_eq!(step.reply, [0, 0, 0, 0]);
    let step = receive(&mut c, &[1], &cfg, CHALLENGE);
    let mut init = vec![1, 64, 0, 200];
    init.extend(pixel_format().encode());
    init.extend(9u32.to_be_bytes());
    init.extend(b"cmux demo");
    assert_eq!(step.reply, init);
    assert_eq!(c.phase, Phase::Normal);
}

#[test]
fn vnc_authentication_checks_the_response() {
    let cfg = config(Some("secret"));
    let mut c = Connection::default();
    let step = receive(&mut c, b"RFB 003.008\n\x02", &cfg, CHALLENGE);
    let mut expected = vec![1, 2];
    expected.extend(CHALLENGE);
    assert_eq!(step.reply, expected);
    assert_eq!(c.phase, Phase::Auth);
    let good = des::vnc_response(b"secret", CHALLENGE);
    let mut ok = c.clone();
    let step = receive(&mut ok, &good, &cfg, CHALLENGE);
    assert_eq!((step.reply.as_slice(), ok.phase), (&[0u8, 0, 0, 0][..], Phase::ClientInit));
    let step = receive(&mut c, &[0; 16], &cfg, CHALLENGE);
    assert_eq!(step.failure.as_deref(), Some("Authentication failed"));
}

#[test]
fn a_security_type_the_server_did_not_offer_fails() {
    let mut c = Connection::default();
    let step = receive(&mut c, b"RFB 003.008\n\x02", &config(None), CHALLENGE);
    assert_eq!(step.failure.as_deref(), Some("unsupported security type"));
    let mut c = Connection::default();
    let step = receive(&mut c, b"RFB 003.008\n\x01", &config(Some("x")), CHALLENGE);
    assert_eq!(step.failure.as_deref(), Some("unsupported security type"));
}

#[test]
fn client_messages_become_events() {
    let cfg = config(None);
    let mut c = Connection::default();
    to_normal(&mut c, &cfg);
    let mut input = vec![0; 20]; // SetPixelFormat, ignored
    input.extend([2, 0, 0, 2]);
    input.extend(16i32.to_be_bytes());
    input.extend(ENCODING_CURSOR.to_be_bytes());
    input.extend([4, 1, 0, 0, 0, 0, 0xFF, 0xE1]); // shift down
    input.extend([4, 1, 0, 0, 0, 0, 0, 0x41]);
    input.extend([5, 1, 0, 10, 0, 20]);
    input.extend([6, 0, 0, 0, 0, 0, 0, 2, b'h', b'i']);
    input.extend([3, 0, 0, 0, 0, 0, 1, 64, 0, 200]);
    input.extend([5, 0]); // half a pointer event waits
    let step = receive(&mut c, &input, &cfg, CHALLENGE);
    assert_eq!(step.consumed, input.len() - 2);
    assert_eq!(c.encodings, [ENCODING_ZRLE, ENCODING_CURSOR]);
    assert_eq!(
        step.events,
        [
            Event::Key { keysym: 0xFFE1, down: true, shift: true },
            Event::Key { keysym: 0x41, down: true, shift: true },
            Event::Pointer { x: 10, y: 20, left_down: true },
            Event::FullUpdate,
        ]
    );
    assert!(step.flush && c.requested);
    assert!(uses_zrle(&c));
    let step = receive(&mut c, &[9], &cfg, CHALLENGE);
    assert_eq!(step.failure.as_deref(), Some("unknown message 9"));
}

#[test]
fn an_update_goes_once_asked_with_the_cursor_first() {
    let cfg = config(None);
    let mut c = Connection::default();
    assert_eq!(flush(&mut c, true), None, "not before the handshake");
    to_normal(&mut c, &cfg);
    assert_eq!(flush(&mut c, true), None, "not before a request");
    c.requested = true;
    assert_eq!(flush(&mut c, false), None, "no damage, no cursor wanted");
    c.encodings = vec![ENCODING_CURSOR];
    assert_eq!(flush(&mut c, false), Some(true));
    assert!(!c.requested && c.cursor_sent);
    c.requested = true;
    assert_eq!(flush(&mut c, false), None);
    assert_eq!(flush(&mut c, true), Some(false));
}

#[test]
fn failure_and_headers_are_big_endian() {
    assert_eq!(failure("no"), [0, 0, 0, 1, 0, 0, 0, 2, b'n', b'o']);
    assert_eq!(update_header(3), [0, 0, 0, 3]);
    assert_eq!(rect_header(1, 2, 3, 4, ENCODING_ZRLE), [0, 1, 0, 2, 0, 3, 0, 4, 0, 0, 0, 16]);
    assert_eq!(raw(&[0x00112233]), [0x33, 0x22, 0x11, 0x00]);
}

#[test]
fn zrle_tiles_pick_solid_rle_or_raw() {
    // Solid: one tile.
    assert_eq!(zrle_tiles(&[0x00AABBCC; 4], 2, 2), [1, 0xCC, 0xBB, 0xAA]);
    // Two runs of 32 in a 64-pixel row: plain RLE is smaller.
    let mut runs = vec![1u32; 32];
    runs.extend([2u32; 32]);
    assert_eq!(zrle_tiles(&runs, 64, 1), [128, 1, 0, 0, 31, 2, 0, 0, 31]);
    // Every pixel different: raw.
    assert_eq!(zrle_tiles(&[1, 2], 2, 1), [0, 1, 0, 0, 2, 0, 0]);
    // A run over 255 continues with 255s.
    let mut long = vec![5u32; 300];
    long.push(6);
    let out = zrle_tiles(&long, 301, 1);
    // 301 wide: tiles of 64, 64, 64, 64, 45.
    assert_eq!(&out[..4], [1, 5, 0, 0]);
    let last = &out[out.len() - 9..];
    assert_eq!(last, [128, 5, 0, 0, 43, 6, 0, 0, 0]);
    // Tiles go row by row of 64.
    assert_eq!(zrle_tiles(&vec![0u32; 70 * 70], 70, 70).len(), 4 * 4);
}

#[test]
fn zrle_tiles_round_trip_through_the_decoder() {
    use crate::framebuffer::{Framebuffer, Rect};
    let (width, height) = (130usize, 70usize);
    // Solid, run and noisy tiles.
    let pixels: Vec<u32> = (0..width * height)
        .map(|i| match (i % width) / 64 {
            0 => 0x0010_2030,
            1 => {
                if i % 9 < 5 {
                    0x00FF_0000
                } else {
                    0x0000_FF00
                }
            }
            _ => (i as u32).wrapping_mul(2_654_435_761) & 0xFF_FFFF,
        })
        .collect();
    let tiles = zrle_tiles(&pixels, width, height);
    let mut fb = Framebuffer::new(width as u16, height as u16).unwrap();
    let rect = Rect::new(0, 0, width as u16, height as u16);
    crate::decode::zrle::decode(&tiles, &mut fb, &pixel_format(), &rect).unwrap();
    for (i, rgba) in fb.pixels().chunks_exact(4).enumerate() {
        let p = pixels[i];
        assert_eq!(&rgba[..3], [(p >> 16) as u8, (p >> 8) as u8, p as u8], "pixel {i}");
    }
}

#[test]
fn the_cursor_is_twelve_by_eighteen() {
    let rect = cursor_rectangle();
    assert_eq!(&rect[..12], rect_header(0, 0, 12, 18, ENCODING_CURSOR));
    assert_eq!(rect.len(), 12 + 12 * 18 * 4 + 2 * 18);
    // The tip's mask bit is set, its far corner's is not.
    let mask = &rect[12 + 12 * 18 * 4..];
    assert_eq!(mask[0] & 0x80, 0x80);
    assert_eq!(mask[1] & 0x10, 0);
}
