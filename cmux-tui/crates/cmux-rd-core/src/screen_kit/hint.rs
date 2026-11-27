//! Where the trackpad hint's hand is at a moment.

/// Positions as fractions of the pad, the press as a scale, the tap's
/// ripple and the fade in and out. Each of the two strokes glides from
/// lower left to upper right, then taps.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HintPose {
    pub x: f64,
    pub y: f64,
    pub scale: f64,
    pub ripple: f64,
    pub opacity: f64,
}

impl Default for HintPose {
    /// The still hand (Reduce Motion), in the middle.
    fn default() -> Self {
        Self { x: 0.5, y: 0.55, scale: 1.0, ripple: 0.0, opacity: 1.0 }
    }
}

fn ease(t: f64) -> f64 {
    t * t * (3.0 - 2.0 * t)
}

impl HintPose {
    /// The pose at `progress` (0...1 through the hint); `None`: the still hand.
    pub fn at(progress: Option<f64>) -> Self {
        let mut pose = Self::default();
        let Some(progress) = progress else { return pose };
        let t = progress.clamp(0.0, 1.0);
        // Fade in over the first 6 %, out over the last 10 %.
        pose.opacity = 1f64.min(t / 0.06).min((1.0 - t) / 0.10);
        // Two strokes, each 45 % of the hint; the rest is the fade.
        let stroke = (t / 0.45).min(1.999);
        let local = stroke - stroke.floor();
        let (from, to) = ((0.28, 0.70), (0.66, 0.36));
        let glide = ease((local / 0.55).min(1.0));
        pose.x = from.0 + (to.0 - from.0) * glide;
        pose.y = from.1 + (to.1 - from.1) * glide;
        // Between the strokes the hand lifts away and comes back, not jumps.
        if stroke < 1.0 {
            pose.opacity *= 1f64.min((1.0 - local) / 0.06);
        } else {
            pose.opacity *= 1f64.min(local / 0.06);
        }
        // After the glide: press (to 0.86) and release, with a ripple that fades as it grows.
        let tap = ((local - 0.62) / 0.3).max(0.0);
        if tap > 0.0 && tap < 1.0 {
            pose.scale = 1.0 - 0.14 * (std::f64::consts::PI * (tap * 2.0).min(1.0)).sin();
            pose.ripple = if tap < 0.5 { 0.0 } else { 1.0 - (tap - 0.5) * 2.0 };
        }
        if t >= 0.9 {
            (pose.x, pose.y) = to;
        }
        pose
    }
}

#[cfg(test)]
mod tests {
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
}
