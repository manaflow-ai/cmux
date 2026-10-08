//! SVG icon sanitizer (plans/cmux-next/icons.md 1, decision D1).

use sha2::{Digest, Sha256};
use std::fmt::Write as _;

/// Largest accepted SVG icon asset, before and after sanitizing.
pub const MAX_SVG_ICON_BYTES: usize = 64 * 1024;
/// Deepest accepted element nesting, counting the root and dropped elements.
pub(crate) const MAX_SVG_ICON_DEPTH: usize = 32;
/// Most elements accepted in one icon, counting the root and dropped elements.
pub(crate) const MAX_SVG_ICON_ELEMENTS: usize = 4096;

/// Sanitize an SVG icon (not implemented yet).
pub fn sanitize_svg_icon(input: &[u8]) -> anyhow::Result<String> {
    Ok(String::from_utf8_lossy(input).into_owned())
}

/// The icon wire string (`svg:sha256-<64 hex>`) naming sanitized SVG text.
pub fn svg_icon_wire(sanitized: &str) -> String {
    let digest = Sha256::digest(sanitized.as_bytes());
    let mut wire = String::with_capacity(11 + 64);
    wire.push_str("svg:sha256-");
    for byte in digest {
        let _ = write!(wire, "{byte:02x}");
    }
    wire
}

#[cfg(test)]
mod tests;
