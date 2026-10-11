//! What the host's own socket to acpmux needs (CmuxNextAgentPane
//! AcpmuxConnection.swift): the dashboard token as a bearer header (never in
//! the URL), `Origin: cmux-agent://pane`, and the per-launch LocalApp token,
//! read at each handshake from `<acpmux home>/run/localapp.token` and put only
//! in the first `initialize` frame. Neither token ever reaches the page.

use crate::data::policy;
use std::path::{Path, PathBuf};

/// The origin acpmux accepts for the bundled pane (acpmux `server/local_app.rs`).
pub fn pane_origin() -> &'static str {
    &policy().pane_origin
}

/// The upgrade request's `Authorization` value.
pub fn authorization(dashboard_token: &str) -> String {
    format!("Bearer {dashboard_token}")
}

/// `<home>/run/localapp.token` (acpmux `server/local_app.rs` `token_path`).
pub fn local_app_token_path(home: &Path) -> PathBuf {
    home.join("run").join("localapp.token")
}

/// The token in a token file's bytes: 64 lowercase hex characters after
/// trimming whitespace and newlines; None for a file over 256 bytes or any
/// other content.
pub fn parse_local_app_token(bytes: &[u8]) -> Option<String> {
    if bytes.len() > 256 {
        return None;
    }
    let text = String::from_utf8_lossy(bytes);
    let text = text.trim();
    (text.len() == 64 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)))
        .then(|| text.to_owned())
}

/// The token read now from `home` (never cached), None when the file is
/// missing, unreadable or malformed: the pane then connects as remote-origin.
pub fn read_local_app_token(home: &Path) -> Option<String> {
    use std::io::Read;
    // One open, at most 257 bytes: a longer file is refused without reading it all.
    let file = std::fs::File::open(local_app_token_path(home)).ok()?;
    let mut bytes = Vec::with_capacity(257);
    file.take(257).read_to_end(&mut bytes).ok()?;
    parse_local_app_token(&bytes)
}
