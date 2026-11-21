use super::*;

fn resync(payload: Vec<u8>) -> Frame {
    let mut frame = Frame::new(MessageKind::ResyncRequired, payload);
    frame.sequence = 1;
    frame
}

fn encoded(limits: KittyGraphicsLimits) -> Vec<u8> {
    [limits.image_bytes, limits.inflight_bytes, limits.images, limits.placements]
        .iter()
        .flat_map(|value| value.to_le_bytes())
        .collect()
}

fn staged(smart: bool, payload: Vec<u8>) -> HostedTransition {
    HostedFrameStager::new(0, smart).push(resync(payload)).unwrap().unwrap()
}

/// Only a smart connection applies a limits payload in place; an empty
/// payload (older host), an attach gap, a payload of another size or
/// out-of-range limits reconnect as before.
#[test]
fn only_valid_limits_on_a_smart_stream_skip_the_reconnect() {
    let limits = KittyGraphicsLimits::disabled();
    assert!(matches!(
        staged(true, encoded(limits)),
        HostedTransition::KittyGraphicsLimits(applied) if applied == limits
    ));
    assert!(matches!(staged(false, encoded(limits)), HostedTransition::ResyncRequired));
    assert!(matches!(staged(true, Vec::new()), HostedTransition::ResyncRequired));
    assert!(matches!(staged(true, vec![0; 9]), HostedTransition::ResyncRequired));
    assert!(matches!(staged(true, vec![0; 17]), HostedTransition::ResyncRequired));
    assert!(matches!(staged(true, vec![0; 33]), HostedTransition::ResyncRequired));
    let out_of_range = KittyGraphicsLimits { images: u64::MAX, ..limits };
    assert!(out_of_range.validate().is_err());
    assert!(matches!(staged(true, encoded(out_of_range)), HostedTransition::ResyncRequired));
}
