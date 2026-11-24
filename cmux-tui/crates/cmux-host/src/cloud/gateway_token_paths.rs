//! Where the inference gateway bearer lives and the person's opt-in marker (gateway_token.rs keeps the token there,
//! Linux only). Plain paths, on every platform: acpmux's machine vault audit (`acpmux/src/vault/reach.rs`) names
//! them, and it builds and tests on macOS too.

use std::path::{Path, PathBuf};

/// Straight under root's `/run`, never under `/run/cmux` (the work user's): no path above the file is one the work
/// user can replace.
pub const TOKEN_DIR: &str = "/run/cmux-inference-gateway";
pub const TOKEN_FILE: &str = "/run/cmux-inference-gateway/token";

/// The marker the person's setup makes in the work user's home.
pub fn marker(home: &Path) -> PathBuf {
    home.join(".config/cmux/inference-gateway/enabled")
}
