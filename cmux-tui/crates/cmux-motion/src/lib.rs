//! Motion for cmux2 shells, ported from cmux-next (`docs/motion.md`;
//! `plans/cmux-next/motion.md` and `CmuxNextDesign/Motion/*.swift` on
//! `feat-cmux-next`).
//!
//! Every animation asks for a token: springs by response and damping
//! fraction (`MotionSpring`), timed ease-out fades (`MotionFade`) and loops
//! (`MotionLoop`). Springs retarget from their current value and velocity;
//! fades restart from the value on screen. `ui.animationSpeed` (`set_speed`,
//! or `CMUX2_ANIMATION_SPEED=fast|normal|off`) scales every time constant;
//! Reduce Motion makes movement instant and caps fades at 0.1 s.
//!
//! No UI toolkit dependency. A toolkit drives an `Animated<T>` by calling
//! `advance(now, &policy())` once per frame and scheduling another frame
//! only while it returns true. The process-wide settings (`speed`,
//! `policy`, the env vars) are the default `settings` feature; without it the
//! host builds a `MotionPolicy` itself. A `Spring` is a `SpringKind::Size`
//! (a move to 0 uses `disappear`) unless built with `Spring::position`
//! (positions and offsets never switch token). The numbers in `spring.rs`
//! are the only animation timing constants; change them together with
//! `docs/motion.md`.

mod clock;
#[cfg(feature = "settings")]
mod settings;
mod spring;

pub use clock::*;
#[cfg(feature = "settings")]
pub use settings::*;
pub use spring::*;
