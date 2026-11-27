//! Text compiled into the binary zstd-compressed, inflated on first use.
//!
//! `include_str!` puts a file's bytes into the binary as they are. The JSON
//! catalogs the cmux binary reads (the settings schema, the resource
//! operation catalog, the action catalog, the Cloud operation catalog) were
//! 13 MB of the macOS `bin/cmux`, some of them twice; zstd packs them 25 to 35
//! times smaller. [`packed_str!`] takes the same `include_str!` call,
//! compresses the file when the crate compiles, and gives a [`PackedStr`]:
//!
//! ```ignore
//! static CATALOG: cmux_embed::PackedStr =
//!     cmux_embed::packed_str!(include_str!("../spec/catalog.json"));
//!
//! let value: serde_json::Value = serde_json::from_str(&CATALOG.inflate())?;
//! let text: &'static str = CATALOG.get();
//! ```
//!
//! Inflating costs about 1 ms per MB. Use [`PackedStr::inflate`] when the text
//! is parsed once and the parse is what is kept, so the text is not held for
//! the life of the process; use [`PackedStr::get`] when a `&'static str` is
//! borrowed (inflated once, then kept, as the `include_str!` text was).

use std::sync::OnceLock;

/// `packed_str!(include_str!("path"))`: the file, zstd-compressed at compile
/// time, as a [`PackedStr`]. The path is resolved as `include_str!` resolves
/// it (relative to the calling file, or
/// `concat!(env!("CARGO_MANIFEST_DIR"), "/path")`), the file is a rebuild
/// dependency, and the build proves the bytes inflate back to the file.
pub use cmux_embed_macros::packed_str;

/// A text compiled in zstd-compressed by [`packed_str!`].
pub struct PackedStr {
    packed: &'static [u8],
    len: usize,
    text: OnceLock<&'static str>,
}

impl PackedStr {
    /// What [`packed_str!`] expands to; not for direct use.
    #[doc(hidden)]
    pub const fn __new(packed: &'static [u8], len: usize) -> Self {
        Self { packed, len, text: OnceLock::new() }
    }

    /// The text, inflated on the first call and kept for the life of the
    /// process.
    pub fn get(&'static self) -> &'static str {
        self.text.get_or_init(|| self.inflate().leak())
    }

    /// A new copy of the text. [`packed_str!`] proved at compile time that the
    /// bytes inflate to the file, so this is the file's text; it is empty only
    /// if the binary itself is damaged.
    pub fn inflate(&self) -> String {
        if let Some(text) = self.text.get() {
            return (*text).to_owned();
        }
        zstd::bulk::decompress(self.packed, self.len)
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .unwrap_or_default()
    }

    /// The text's length in bytes.
    pub const fn len(&self) -> usize {
        self.len
    }

    /// True for an empty text.
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// The compressed length: what the text costs in the binary.
    pub const fn packed_len(&self) -> usize {
        self.packed.len()
    }
}
