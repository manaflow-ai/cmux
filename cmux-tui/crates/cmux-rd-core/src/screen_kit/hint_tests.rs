use super::*;

#[test]
fn the_hand_glides_taps_and_fades() {
    assert_eq!(HintPose::at(None), HintPose::default());
    let start = HintPose::at(Some(0.0));
    assert_eq!((start.x, start.y, start.opacity), (0.28, 0.70, 0.0));
    let gliding = HintPose::at(Some(0.12));
    assert!(gliding.x > 0.28 && gliding.x < 0.66 && gliding.opacity == 1.0);
    // local = 0.695: tap = 0.25, the deepest press.
    let pressed = HintPose::at(Some(0.45 * 0.695));
    assert!((pressed.scale - 0.86).abs() < 1e-6 && pressed.ripple == 0.0);
    let rippling = HintPose::at(Some(0.45 * 0.83));
    assert!(rippling.ripple > 0.0 && rippling.ripple < 1.0 && rippling.scale > 0.86);
    let end = HintPose::at(Some(1.0));
    assert_eq!((end.x, end.y, end.opacity), (0.66, 0.36, 0.0));
    assert_eq!(HintPose::at(Some(2.0)), end, "clamped");
}
