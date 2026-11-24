//! Where the inference gateway's bearer lives and the marker that opts a machine in, on every platform:
//! [`super::gateway_token`], the thread that writes the bearer, runs only on Linux, but acpmux's machine vault audit
//! (`acpmux/src/vault/reach.rs`) names these paths in a build for any platform.

use std::path::{Path, PathBuf};

/// Straight under root's `/run`, never under `/run/cmux` (the work user's): no path above the file is one the work
/// user can replace.
pub const TOKEN_DIR: &str = "/run/cmux-inference-gateway";
pub const TOKEN_FILE: &str = "/run/cmux-inference-gateway/token";

/// The marker the person's setup makes in the work user's home.
pub fn marker(home: &Path) -> PathBuf {
    home.join(".config/cmux/inference-gateway/enabled")
}
