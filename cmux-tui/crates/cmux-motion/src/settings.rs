//! Process-wide motion settings: animation speed, Reduce Motion and the
//! screen-recording time scale. These are the crate's only global state:
//! two atomics behind documented setters (`set_speed`,
//! `set_reduce_motion_override`), plus environment values read once.
//! Callers that want no globals build a `MotionPolicy` themselves and pass
//! it to `Spring::step` / `Animated::advance`; `policy()` is a convenience.

use std::sync::{
    OnceLock,
    atomic::{AtomicU8, Ordering},
};

use crate::{MotionPolicy, MotionSpeed};

const UNSET: u8 = u8::MAX;
static SPEED: AtomicU8 = AtomicU8::new(UNSET);
static REDUCE_OVERRIDE: AtomicU8 = AtomicU8::new(UNSET);

fn speed_code(s: MotionSpeed) -> u8 {
    match s {
        MotionSpeed::Fast => 0,
        MotionSpeed::Normal => 1,
        MotionSpeed::Off => 2,
    }
}

/// `ui.animationSpeed`. Starts from `CMUX2_ANIMATION_SPEED`, else `fast`.
pub fn speed() -> MotionSpeed {
    match SPEED.load(Ordering::Relaxed) {
        0 => MotionSpeed::Fast,
        1 => MotionSpeed::Normal,
        2 => MotionSpeed::Off,
        _ => {
            let s = std::env::var("CMUX2_ANIMATION_SPEED")
                .ok()
                .and_then(|v| MotionSpeed::parse(&v))
                .unwrap_or_default();
            SPEED.store(speed_code(s), Ordering::Relaxed);
            s
        }
    }
}

/// Changes `ui.animationSpeed` for the whole process. Running animations
/// pick up the new speed on their next frame.
pub fn set_speed(s: MotionSpeed) {
    SPEED.store(speed_code(s), Ordering::Relaxed);
}

/// Pins Reduce Motion (tests, a future setting); `None` follows the system.
pub fn set_reduce_motion_override(value: Option<bool>) {
    REDUCE_OVERRIDE.store(value.map_or(UNSET, u8::from), Ordering::Relaxed);
}

/// `CMUX2_REDUCE_MOTION`: `0`/`false`/`no`/`off` forces it off, any other
/// value forces it on, unset follows the system.
fn env_reduce_motion() -> Option<bool> {
    static ENV: OnceLock<Option<bool>> = OnceLock::new();
    *ENV.get_or_init(|| {
        std::env::var("CMUX2_REDUCE_MOTION").ok().map(|v| {
            !matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "no" | "off")
        })
    })
}

/// The system Reduce Motion setting: macOS
/// `NSWorkspace.accessibilityDisplayShouldReduceMotion`; Linux GNOME
/// `enable-animations` (else `gtk-enable-animations`); Windows "Animation
/// effects" (`SPI_GETCLIENTAREAANIMATION`). Linux and Windows keep it
/// current from a watcher thread (`system.rs`); false on other systems.
pub fn system_reduce_motion() -> bool {
    #[cfg(target_os = "macos")]
    {
        objc2_app_kit::NSWorkspace::sharedWorkspace().accessibilityDisplayShouldReduceMotion()
    }
    #[cfg(not(target_os = "macos"))]
    {
        crate::system::reduce_motion()
    }
}

/// Reduce Motion: the override, else `CMUX2_REDUCE_MOTION`, else the system.
pub fn reduce_motion() -> bool {
    match REDUCE_OVERRIDE.load(Ordering::Relaxed) {
        0 => false,
        1 => true,
        _ => env_reduce_motion().unwrap_or_else(system_reduce_motion),
    }
}

/// `CMUX2_ANIM_SCALE=8` slows every animation down for screen recordings.
fn debug_scale() -> f64 {
    static SCALE: OnceLock<f64> = OnceLock::new();
    *SCALE.get_or_init(|| {
        std::env::var("CMUX2_ANIM_SCALE")
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .unwrap_or(1.)
            .max(1.)
    })
}

/// The live policy: speed, Reduce Motion and the recording scale.
pub fn policy() -> MotionPolicy {
    MotionPolicy { debug_scale: debug_scale(), ..MotionPolicy::new(speed(), reduce_motion()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MotionFade, MotionSpring};

    /// The only test in this crate that touches the globals.
    #[test]
    fn global_settings() {
        set_speed(MotionSpeed::Normal);
        set_reduce_motion_override(Some(true));
        let p = policy();
        assert_eq!(p.speed, MotionSpeed::Normal);
        assert!(p.reduce_motion);
        assert!(!p.animates_movement());
        assert_eq!(p.spring_duration(MotionSpring::Move), 0.);
        set_reduce_motion_override(Some(false));
        let d = policy().spring_duration(MotionSpring::Move);
        assert!((d - 1.5 * MotionSpring::Move.base().visible_end()).abs() < 0.01);
        set_speed(MotionSpeed::Off);
        assert_eq!(policy().fade(MotionFade::FadeIn), 0.);
        set_speed(MotionSpeed::Fast);
        set_reduce_motion_override(None);
        assert_eq!(speed(), MotionSpeed::Fast);
    }
}
