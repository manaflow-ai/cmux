//! Process-wide motion settings: animation speed, Reduce Motion, the
//! `ui.animations.*` switches and the screen-recording time scale. These
//! are the crate's only global state: three atomics behind documented
//! setters (`set_speed`, `set_reduce_motion_override`,
//! `set_animation_switches`), plus environment values read once. The host
//! reads its own settings file and calls the setters; this crate never
//! reads a settings file.
//! Callers that want no globals build a `MotionPolicy` themselves and pass
//! it to `Spring::step` / `Animated::advance`; `policy()` is a convenience.

use std::sync::{
    OnceLock,
    atomic::{AtomicU8, Ordering},
};

use crate::{AnimationSwitches, MotionBounce, MotionPolicy, MotionSpeed};

const UNSET: u8 = u8::MAX;
static SPEED: AtomicU8 = AtomicU8::new(UNSET);
static REDUCE_OVERRIDE: AtomicU8 = AtomicU8::new(UNSET);
/// `AnimationSwitches` as bits (1 paneAnimations, 2 newTab, 4 newWorkspace, 8
/// bounce subtle); `UNSET` until the host sets them (the spec defaults).
static SWITCHES: AtomicU8 = AtomicU8::new(UNSET);

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

/// Changes the `ui.animations.*` settings (per-kind switches and bounce)
/// for the whole process. Running animations pick them up on their next
/// frame.
pub fn set_animation_switches(switches: AnimationSwitches) {
    let bits = u8::from(switches.pane_animations)
        | (u8::from(switches.new_tab) << 1)
        | (u8::from(switches.new_workspace) << 2)
        | (u8::from(switches.bounce == MotionBounce::Subtle) << 3);
    SWITCHES.store(bits, Ordering::Relaxed);
}

/// The `ui.animations.*` settings: the last `set_animation_switches`, else
/// the spec defaults.
pub fn animation_switches() -> AnimationSwitches {
    match SWITCHES.load(Ordering::Relaxed) {
        UNSET => AnimationSwitches::DEFAULT,
        bits => AnimationSwitches {
            pane_animations: bits & 1 != 0,
            new_tab: bits & 2 != 0,
            new_workspace: bits & 4 != 0,
            bounce: if bits & 8 != 0 { MotionBounce::Subtle } else { MotionBounce::None },
        },
    }
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

/// The live policy: speed, Reduce Motion, the `ui.animations.*` switches
/// and the recording scale.
pub fn policy() -> MotionPolicy {
    MotionPolicy {
        debug_scale: debug_scale(),
        animations: animation_switches(),
        ..MotionPolicy::new(speed(), reduce_motion())
    }
}
