use super::*;

#[test]
fn frames_are_counted_after_the_upgrade() {
    let wire = Wire::default();
    let mut c = FrameCounter::default();
    // Upgrade, then a masked ping with 4 bytes, then an unmasked 300-byte text frame split.
    let mut bytes = b"GET / HTTP/1.1\r\nUpgrade: websocket\r\n\r\n".to_vec();
    bytes.extend([0x89, 0x84, 1, 2, 3, 4, 9, 9, 9, 9]);
    bytes.extend([0x81, 126, 0x01, 0x2c]);
    bytes.extend(vec![b'x'; 300]);
    bytes.extend([0x8a, 0x00]);
    for chunk in bytes.chunks(7) {
        c.feed(chunk, &wire);
    }
    assert_eq!(wire.frames.load(Ordering::Relaxed), 3);
    assert_eq!(wire.pings.load(Ordering::Relaxed), 1);
    assert_eq!(wire.pongs.load(Ordering::Relaxed), 1);
    assert_eq!(wire.data.load(Ordering::Relaxed), 1);
}

#[test]
fn base64_matches() {
    assert_eq!(base64_encode(b"hello"), "aGVsbG8=");
    assert_eq!(base64_encode(b"hi!"), "aGkh");
    assert_eq!(base64_encode(b"a"), "YQ==");
}

#[test]
fn peerscale_expands() {
    let legs = expand(vec!["baseline".into(), "peerscale".into()]);
    assert_eq!(legs, ["baseline", "peerscale1", "peerscale10", "peerscale20", "peerscale40"]);
    assert_eq!(peers_for("peerscale20", 2), 20);
    assert_eq!(peers_for("host150", 2), 40);
    assert_eq!(peers_for("cpu", 2), 2);
}
