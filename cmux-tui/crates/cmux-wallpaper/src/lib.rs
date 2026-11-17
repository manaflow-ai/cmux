//! cmux NEXT live wallpapers (plans/cmux-next/live-wallpapers.md): a window
//! backdrop drawn by a small WGSL program, one fragment function the GPU runs
//! for each pixel.
//!
//! - [`manifest`]: `wallpaper.json`, parsed and checked; errors carry a JSON pointer.
//! - [`program`]: the program's sandbox (no bindings, entry points, textures,
//!   samplers, storage, `var<workgroup>` or `var<private>`) and its translation
//!   with naga to Metal Shading Language (the Mac) and GLSL ES 3.00 (the gallery
//!   and the still renderer). The app never compiles WGSL itself.
//! - [`frame`]: the 144-byte `Frame` uniform (`prelude.wgsl`) and the pointer's
//!   smoothing (velocity, presence), so the host does no math.
//! - [`schedule`]: when a wallpaper draws: hold at zero work, idle, the frame
//!   cap and the GPU budget.
//! - [`first_party`]: the wallpapers under `wallpapers/`, embedded in the binary.
//!
//! Pure: no I/O, no globals, no threads. The caller passes every byte in.

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6), as in cmux-app-manifest.
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit,
        clippy::indexing_slicing
    )
)]

pub mod first_party;
pub mod frame;
pub mod manifest;
pub mod program;
pub mod schedule;

pub use first_party::{FirstParty, first_party, first_party_at, first_party_by_id, smoke};
pub use frame::{FRAME_BYTES, FRAME_FLOATS, FrameInput, PointerState, pack_frame, srgb_to_linear};
pub use manifest::{Manifest, ManifestError, ManifestErrorKind, Param, Still, Variant};
pub use program::{
    Compiled, MAX_SOURCE_BYTES, ProgramError, ProgramErrorKind, compile, compile_bytes,
};
pub use schedule::{Decision, HoldReason, ScheduleInput, gpu_strikes, schedule};
