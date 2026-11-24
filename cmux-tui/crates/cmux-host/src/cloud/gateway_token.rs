//! The bearer of this machine's inference gateway (`cmux inference gateway --token-file`), when the person made this
//! machine their team's gateway machine (cmux-platform `InferenceGateway.ts`: a machine holds the team's gateway socket
//! as its own VM install, and only when the team named it).
//!
//! Leo, 2026-11-07: "what we are willing to do for now is a tiny vm per subscription (user)/per team. that's it."
//!
//! Opt-in: only while the work user's `~/.config/cmux/inference-gateway/enabled` exists (`cmux inference setup`
//! makes it; checked for existence only, never followed or read). While it does, this thread keeps a fresh access
//! token of this machine's own install in [`TOKEN_FILE`], 0600 and owned by the work user, in a folder only root
//! writes, so no path the work user controls is ever written by root. Without the marker the file is removed. The
//! token is the one cmux-host itself uses; it acts only as this machine's install, and lives minutes. It is never
//! logged.
//!
//! The paths and the marker are plain and build everywhere (acpmux's vault reach audit reads them on macOS too); the
//! thread is Linux-only ([`linux`]).

use std::path::{Path, PathBuf};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::*;

/// Straight under root's `/run`, never under `/run/cmux` (the work user's): no path above the file is one the work
/// user can replace.
pub const TOKEN_DIR: &str = "/run/cmux-inference-gateway";
pub const TOKEN_FILE: &str = "/run/cmux-inference-gateway/token";

/// The marker the person's setup makes in the work user's home.
pub fn marker(home: &Path) -> PathBuf {
    home.join(".config/cmux/inference-gateway/enabled")
}
