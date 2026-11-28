//! Motion for cmux2 shells, ported from cmux-next (`docs/motion.md`;
//! `plans/cmux-next/motion.md` and `CmuxNextDesign/Motion/*.swift` on
//! `feat-cmux-next`).
//!
//! Every animation asks for a token: springs by response and damping
//! fraction (`MotionSpring`), timed ease-out fades (`MotionFade`) and loops
//! (`MotionLoop`), and the hover marquee (`MotionPolicy::marquee`,
//! `MarqueeTiming`). Springs retarget from their current value and velocity;
//! fades restart from the value on screen. `ui.animationSpeed` (`set_speed`,
//! or `CMUX2_ANIMATION_SPEED=fast|normal|off`) scales every time constant;
//! Reduce Motion makes movement instant and caps fades at 0.1 s.
//!
//! No UI toolkit dependency. A toolkit drives an `Animated<T>` by calling
//! `advance(now, &policy())` once per frame and scheduling another frame
//! only while it returns true. The process-wide settings (`speed`,
//! `policy`, the env vars) are the default `settings` feature; without it the
//! host builds a `MotionPolicy` itself. The system Reduce Motion setting is
//! read on macOS, Linux and Windows (`system_reduce_motion`; on Linux and
//! Windows a watcher thread keeps it current). A `Spring` is a `SpringKind::Size`
//! (a move to 0 uses `disappear`) unless built with `Spring::position`
//! (positions and offsets never switch token).
//!
//! The token numbers (springs, fades, loops, speed, the bounce, the settle
//! thresholds, the structural set and the per-kind switch defaults) are read
//! at build time from the spec's `design-tokens.json` (`motion`; build.rs),
//! the same file cmux-next macOS and cmux-theme-tokens read. Springs step in
//! closed form (`SpringValue::solve`), so a path is exact at any frame rate.
//! Structural springs (`MotionSpring::is_structural`) follow
//! `ui.animations.bounce`; `ui.paneAnimations`, `ui.animations.newTab` and
//! `ui.animations.newWorkspace` turn one kind on (`MotionPolicy::animates`;
//! newTab on by default, the others off). The host passes these settings
//! in (`set_animation_switches` or `MotionPolicy::with_animations`).
//!
//! The tab strip moves like Chrome's: `Tween`s (`MotionTween`, 200 ms
//! `ease_out_quad`) that restart from the value on screen on a new target,
//! with the strip geometry in `TabStripGeometry` (design-tokens.json
//! `motion.tweens`, `motion.tabStrip`).

mod clock;
mod color;
mod fade;
mod marquee;
mod policy;
#[cfg(feature = "settings")]
mod settings;
mod spring;
mod tab_strip;
mod tokens;
mod tween;
// The Reduce Motion reading off macOS (macOS asks NSWorkspace in settings.rs).
#[cfg(all(feature = "settings", not(target_os = "macos")))]
mod system;

pub use clock::*;
pub use color::*;
pub use fade::*;
pub use marquee::*;
pub use policy::*;
#[cfg(feature = "settings")]
pub use settings::*;
pub use spring::*;
pub use tab_strip::*;
pub use tokens::*;
pub use tween::*;
