//! Where the inference gateway's token and the person's opt-in marker live, on every platform: only Linux runs the
//! thread that keeps the token ([`super::gateway_token`]), but acpmux's machine vault audit names these paths on any
//! machine it builds for, the Mac included.

use std::path::{Path, PathBuf};

/// Straight under root's `/run`, never under `/run/cmux` (the work user's): no path above the file is one the work
/// user can replace.
pub const TOKEN_DIR: &str = "/run/cmux-inference-gateway";
pub const TOKEN_FILE: &str = "/run/cmux-inference-gateway/token";

/// The marker the person's setup makes in the work user's home.
pub fn marker(home: &Path) -> PathBuf {
    home.join(".config/cmux/inference-gateway/enabled")
}
