//! cmux NEXT live wallpapers (plans/cmux-next/live-wallpapers.md): a window
//! backdrop drawn by a small WGSL program, one fragment function the GPU runs
//! for each pixel.
//!
//! - [`manifest`]: `wallpaper.json`, parsed and checked; errors carry a JSON pointer.
//! - `program` (feature `compile`): the program's sandbox (no bindings, entry
//!   points, textures, samplers, storage, `var<workgroup>` or `var<private>`)
//!   and its translation with naga to Metal Shading Language (the Mac) and
//!   GLSL ES 3.00. build.rs runs the same code on every first-party program,
//!   so shipped binaries carry Metal source and no shader compiler.
//! - [`frame`]: the 144-byte `Frame` uniform (`prelude.wgsl`) and the pointer's
//!   smoothing (velocity, presence), so the host does no math.
//! - [`schedule`]: when a wallpaper draws: hold at zero work, idle, the frame
//!   cap and the GPU budget.
//! - [`first_party`]: the wallpapers under `wallpapers/`, embedded in the
//!   binary with their build-time Metal.
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
#[cfg(feature = "compile")]
pub mod program;
pub mod schedule;

pub use first_party::{FirstParty, first_party, first_party_at, first_party_by_id, smoke};
pub use frame::{
    ActivityState, FRAME_BYTES, FRAME_FLOATS, FrameInput, PointerState, pack_frame, srgb_to_linear,
};
pub use manifest::{Manifest, ManifestError, ManifestErrorKind, Param, Still, Variant};
#[cfg(feature = "compile")]
pub use program::{Compiled, ProgramError, ProgramErrorKind, compile, compile_bytes};
pub use schedule::{Decision, HoldReason, ScheduleInput, gpu_strikes, schedule};

/// The largest program accepted (`program::MAX_SOURCE_BYTES`, also without `compile`).
pub const MAX_SOURCE_BYTES: usize = 64 * 1024;

/// True when this build checks programs (feature `compile`).
pub const CHECKS_PROGRAMS: bool = cfg!(feature = "compile");

/// What [`check_program`] found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProgramCheck {
    /// The program passed the sandbox and translates to Metal and GLSL.
    Passed,
    /// Refused, with the line and column (1-based) in the source when known.
    Refused { message: String, location: Option<(u32, u32)> },
    /// This build has no program check (feature `compile` is off): nothing
    /// was checked, and the program is neither passed nor refused.
    NotChecked,
}

/// Checks a program's bytes when this build can ([`CHECKS_PROGRAMS`]). Nothing
/// of the check stays alive after it returns.
pub fn check_program(source: &[u8]) -> ProgramCheck {
    #[cfg(feature = "compile")]
    {
        match compile_bytes(source) {
            Ok(_) => ProgramCheck::Passed,
            Err(e) => ProgramCheck::Refused { message: e.message, location: e.location },
        }
    }
    #[cfg(not(feature = "compile"))]
    {
        let _ = source;
        ProgramCheck::NotChecked
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_program_says_what_this_build_did() {
        let ok = b"fn wallpaper(px: vec2<f32>) -> vec4<f32> { return frame.paper; }\n";
        let bad = b"var<private> n: f32;\nfn wallpaper(px: vec2<f32>) -> vec4<f32> { return frame.paper; }\n";
        if CHECKS_PROGRAMS {
            assert_eq!(check_program(ok), ProgramCheck::Passed);
            assert!(matches!(
                check_program(bad),
                ProgramCheck::Refused { location: Some((1, _)), .. }
            ));
        } else {
            assert_eq!(check_program(ok), ProgramCheck::NotChecked);
            assert_eq!(check_program(bad), ProgramCheck::NotChecked);
        }
    }

    #[cfg(feature = "compile")]
    #[test]
    fn the_source_cap_is_the_programs() {
        assert_eq!(MAX_SOURCE_BYTES, program::MAX_SOURCE_BYTES);
    }
}
