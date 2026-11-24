//! Where this machine's inference gateway bearer and its opt-in marker live ([`super::gateway_token`] keeps them on a
//! Linux Cloud machine). Paths only, on every OS: acpmux's machine vault audit (`vault/reach.rs`) names them on a Mac
//! build too, where the Linux-only thread that writes them is not compiled.

use std::path::{Path, PathBuf};

/// Straight under root's `/run`, never under `/run/cmux` (the work user's): no path above the file is one the work
/// user can replace.
pub const TOKEN_DIR: &str = "/run/cmux-inference-gateway";
pub const TOKEN_FILE: &str = "/run/cmux-inference-gateway/token";

/// The marker the person's setup makes in the work user's home.
pub fn marker(home: &Path) -> PathBuf {
    home.join(".config/cmux/inference-gateway/enabled")
}
