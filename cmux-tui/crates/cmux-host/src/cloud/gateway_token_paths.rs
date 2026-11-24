//! Where the inference gateway's token and opt-in marker live ([`super::gateway_token`] keeps them, on Linux only).
//! Plain paths, so a reader on any target (the machine vault audit, `acpmux` `vault/reach.rs`) names the same files.

use std::path::{Path, PathBuf};

/// Straight under root's `/run`, never under `/run/cmux` (the work user's): no path above the file is one the work
/// user can replace.
pub const TOKEN_DIR: &str = "/run/cmux-inference-gateway";
pub const TOKEN_FILE: &str = "/run/cmux-inference-gateway/token";

/// The marker the person's setup makes in the work user's home.
pub fn marker(home: &Path) -> PathBuf {
    home.join(".config/cmux/inference-gateway/enabled")
}
