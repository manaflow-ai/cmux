//! cmux-shotdiff: the one screenshot comparator and golden store every screenshot gate shares (iOS on Linux,
//! the macOS app verified on Linux, cmux-fp on Linux and Windows, the web view gallery).
//!
//! - [`compare::compare`]: perceptual diff of two RGBA images: SSIM on luma plus a per-pixel channel
//!   tolerance, ignore masks (caret, clock, animation) and named regions with their own thresholds. Returns a
//!   JSON [`compare::Verdict`] and a diff image. Deterministic to the byte.
//! - [`store::Store`]: goldens addressed by the hash of their decoded pixels, named in a sorted manifest.
//! - [`store::batch`]: a directory of fresh screenshots against the store, one report (the CI step).
//! - [`inputkey`]: the key of a family's inputs at a git revision, so a Mac renders a golden once per change of
//!   what it depends on (mac-golden-cache).
//!
//! The CLI (`cmux-shotdiff --help`) wraps all three. Linux-hosted gates and Mac-hosted ones use the same
//! binary, so a golden blessed on a Mac judges a Linux render with the same numbers.

pub mod compare;
pub mod image;
pub mod inputkey;
pub mod store;

pub use compare::{Comparison, Mask, Rect, Region, Spec, Verdict, compare};
pub use image::{Rgba, decode_png, encode_png};
pub use store::{BatchOptions, Report, Store, batch};
