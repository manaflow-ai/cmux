//! Parity with CursorShapeTests.swift (the image decoding tests stay Swift).
use super::*;

fn shape(png: &[u8], w: f64, hx: f64) -> CursorShape {
    use base64::Engine;
    CursorShape {
        id: shape_id(png, 5.0, 5.0),
        png: base64::engine::general_purpose::STANDARD.encode(png),
        w,
        h: 0.04,
        hx,
        hy: 0.125,
        pw: 28.0,
        ph: 40.0,
    }
}

fn png(width: u8) -> Vec<u8> {
    // Stand-ins for distinct images: the id only hashes bytes.
    vec![0x89, b'P', b'N', b'G', width, 1]
}

#[test]
fn a_viewer_asks_for_shapes_beside_telepointers() {
    let caps = Some("telepointers,cursor-shape");
    assert!(viewer_draws_pointers("caps", caps), "an older host still reads telepointers");
    assert!(viewer_draws_cursor_shapes("caps", caps));
    assert!(viewer_draws_cursor_shapes("caps", Some(" telepointers , cursor-shape ")));
    assert!(!viewer_draws_cursor_shapes("caps", Some("telepointers")), "an older viewer");
    assert!(
        !viewer_draws_cursor_shapes("caps", Some("cursor-shape")),
        "shapes only with telepointers"
    );
    assert!(!viewer_draws_cursor_shapes("text", caps));
    assert!(!viewer_draws_pointers("caps", None));
}

#[test]
fn the_shape_message_round_trips() {
    let s = shape(&png(2), 0.02, 0.2);
    let value: serde_json::Value = serde_json::from_str(&s.message()).unwrap();
    assert_eq!(value["t"], "cursor");
    let back: CursorShape = serde_json::from_value(value["cursor"].clone()).unwrap();
    assert_eq!(back, s);
}

#[test]
fn the_id_follows_the_image_and_hotspot() {
    let (one, two) = (png(2), png(3));
    assert_eq!(shape_id(&one, 0.0, 0.0), shape_id(&one, 0.0, 0.0));
    assert_ne!(shape_id(&one, 0.0, 0.0), shape_id(&two, 0.0, 0.0));
    assert_ne!(shape_id(&one, 0.0, 0.0), shape_id(&one, 1.0, 0.0));
}

#[test]
fn the_id_is_fnv1a_in_unpadded_hex() {
    // FNV-1a 64 of no bytes is its offset basis; then 16 zero bytes (two 0.0s).
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for _ in 0..16 {
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    assert_eq!(shape_id(&[], 0.0, 0.0), format!("{hash:x}"));
    assert!(!shape_id(b"a", 1.5, 2.0).starts_with('0'));
}

#[test]
fn a_viewer_draws_only_a_shape_it_can() {
    let p = png(2);
    assert!(shape(&p, 0.02, 0.2).is_drawable());
    assert!(!shape(&p, 0.0, 0.2).is_drawable(), "no width");
    assert!(!shape(&p, 1.5, 0.2).is_drawable(), "wider than the display");
    assert!(!shape(&p, 0.02, -0.1).is_drawable(), "a hotspot outside the cursor");
    assert!(!shape(&p, f64::NAN, 0.2).is_drawable());
    let mut zero = shape(&p, 0.02, 0.2);
    zero.pw = 0.0;
    assert!(!zero.is_drawable());
}

#[test]
fn the_host_sends_a_shape_once_until_it_forgets_it() {
    let mut sent = SentCursorShapes::default();
    assert!(sent.needs_send("arrow"));
    assert!(!sent.needs_send("arrow"), "already sent");
    for index in 0..SentCursorShapes::CAPACITY - 1 {
        assert!(sent.needs_send(&format!("s{index}")));
    }
    assert!(!sent.needs_send("arrow"), "used again: newest");
    assert!(sent.needs_send("one more"));
    assert!(sent.needs_send("s0"), "the oldest was forgotten and goes again");
    assert_eq!(sent.ids.len(), SentCursorShapes::CAPACITY);
    sent.reset();
    assert!(sent.needs_send("arrow"), "another display: sent again");
}

const DISPLAY: Rect = Rect::new(0.0, 0.0, 1512.0, 982.0);

fn decoded(attempts: &[String]) -> Vec<CursorShape> {
    attempts
        .iter()
        .map(|text| {
            let value: serde_json::Value = serde_json::from_str(text).unwrap();
            assert_eq!(value["t"], CURSOR_SHAPE_TYPE);
            serde_json::from_value(value["cursor"].clone()).unwrap()
        })
        .collect()
}

#[test]
fn a_failed_shape_send_retries_without_another_cursor_read() {
    let mut delivery = CursorShapeDelivery::default();
    let arrow = shape(&png(2), 0.02, 0.2);
    let mut attempts = Vec::new();
    let mut sample = |read: Option<&CursorShape>, writable: bool, attempts: &mut Vec<String>| {
        delivery.current(read, DISPLAY, |text| {
            attempts.push(text.to_owned());
            writable
        })
    };
    assert_eq!(
        sample(Some(&arrow), false, &mut attempts),
        None,
        "a refused send advertises nothing"
    );
    assert_eq!(sample(None, false, &mut attempts), None, "an unchanged cursor still retries");
    assert_eq!(sample(None, true, &mut attempts), Some(arrow.id.clone()));
    assert_eq!(sample(None, true, &mut attempts), Some(arrow.id.clone()));
    assert_eq!(attempts.len(), 3, "one attempt per sample until success");
    assert!(decoded(&attempts).iter().all(|s| *s == arrow));
}

#[test]
fn a_new_cursor_supersedes_the_shape_waiting_to_send() {
    let mut delivery = CursorShapeDelivery::default();
    let arrow = shape(&png(2), 0.02, 0.2);
    let hand = shape(&png(3), 0.02, 0.2);
    let latest = shape(&png(4), 0.02, 0.2);
    let mut attempts = Vec::new();
    let mut sample = |read: Option<&CursorShape>, writable: bool, attempts: &mut Vec<String>| {
        delivery.current(read, DISPLAY, |text| {
            attempts.push(text.to_owned());
            writable
        })
    };
    assert_eq!(sample(Some(&arrow), true, &mut attempts), Some(arrow.id.clone()));
    assert_eq!(
        sample(Some(&hand), false, &mut attempts),
        Some(arrow.id.clone()),
        "keep the delivered one"
    );
    assert_eq!(sample(Some(&latest), true, &mut attempts), Some(latest.id.clone()));
    assert_eq!(sample(None, true, &mut attempts), Some(latest.id.clone()));
    assert_eq!(decoded(&attempts), vec![arrow, hand, latest], "the obsolete hand is not retried");
}

#[test]
fn another_display_discards_pending_shapes_and_resends_its_geometry() {
    let mut delivery = CursorShapeDelivery::default();
    let other = Rect::new(1512.0, 0.0, 756.0, 491.0);
    let arrow = shape(&png(2), 0.02, 0.2);
    let pending = shape(&png(3), 0.02, 0.2);
    let mut resized = arrow.clone();
    resized.w *= 2.0;
    resized.h *= 2.0;
    let mut attempts = Vec::new();
    let mut sample =
        |read: Option<&CursorShape>, display: Rect, writable: bool, attempts: &mut Vec<String>| {
            delivery.current(read, display, |text| {
                attempts.push(text.to_owned());
                writable
            })
        };
    assert_eq!(sample(Some(&arrow), DISPLAY, true, &mut attempts), Some(arrow.id.clone()));
    assert_eq!(sample(Some(&pending), DISPLAY, false, &mut attempts), Some(arrow.id.clone()));
    assert_eq!(
        sample(None, other, true, &mut attempts),
        None,
        "no old geometry on the new display"
    );
    assert_eq!(attempts.len(), 2, "the previous display's pending shape is not retried");
    assert_eq!(sample(Some(&resized), other, true, &mut attempts), Some(resized.id.clone()));
    assert_eq!(sample(None, other, true, &mut attempts), Some(resized.id.clone()));
    assert_eq!(
        decoded(&attempts),
        vec![arrow, pending, resized.clone()],
        "resent with this display's size"
    );
}

#[test]
fn the_shadow_is_macos_s() {
    assert_eq!(SHADOW, (0.45, 2.0, 1.0));
}
