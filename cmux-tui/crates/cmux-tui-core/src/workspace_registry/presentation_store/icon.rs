//! The one icon value every daemon-owned entity stores (plans/cmux-next/icons.md 1):
//! an SF Symbol name, one emoji, or a content-addressed asset reference.

use super::svg_icon::{sanitize_svg_icon, svg_icon_wire};

/// Wire prefix of a sanitized SVG asset reference (`svg:sha256-<64 hex>`).
const SVG_ICON_PREFIX: &str = "svg:";

/// What an asset icon value names: a raster image or a sanitized SVG.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IconAssetKind {
    Raster,
    Svg,
}

/// An icon value that names a stored asset by the SHA-256 of its bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IconAssetRef<'a> {
    pub kind: IconAssetKind,
    pub digest: &'a str,
}

/// The asset an `image:sha256-<hex>` or `svg:sha256-<hex>` value names, or
/// `None` for every other value.
pub fn parse_icon_asset(value: &str) -> Option<IconAssetRef<'_>> {
    let (kind, rest) = if let Some(rest) = value.strip_prefix("image:") {
        (IconAssetKind::Raster, rest)
    } else {
        (IconAssetKind::Svg, value.strip_prefix(SVG_ICON_PREFIX)?)
    };
    let digest = rest.strip_prefix("sha256-")?;
    is_sha256_hex(digest).then_some(IconAssetRef { kind, digest })
}

/// Exactly 64 lowercase hex digits.
pub fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// The format of an icon value for a field that takes assets: an SF Symbol
/// name, one emoji, or an asset reference (`image:sha256-<hex>`,
/// `svg:sha256-<hex>`). Format only: every write path of such a field also
/// calls `personal_store::blobs::require_icon_asset` in its transaction,
/// which requires the named asset to exist in the blob store.
pub fn validate_icon_value(value: &str) -> anyhow::Result<()> {
    if parse_icon_asset(value).is_some() {
        return Ok(());
    }
    anyhow::ensure!(
        !value.starts_with(SVG_ICON_PREFIX) && !value.starts_with("image:"),
        "bad request: icon must be an SF Symbol name (lowercase letters, digits, and dots), one emoji, image:sha256-<64 lowercase hex>, or svg:sha256-<64 lowercase hex>"
    );
    validate_presentation_icon(value)
}

/// An SF Symbol name such as `terminal`, `folder.fill`, or `0.circle`, or
/// exactly one emoji grapheme (shared by every entity with an icon,
/// plans/cmux-next/data-model.md "Shared appearance shape").
///
/// Asset references (`svg:sha256-<hex>`, `image:sha256-<hex>`) are refused
/// here. Fields that take assets (`icon-assets-v1`: workspace, screen, room,
/// browser profile and workspace status icons) check them with
/// `personal_store::blobs::require_icon_asset`, which proves the asset exists
/// and keeps it out of the blob sweep; the store's put path accepts an SVG
/// only through [`validate_presentation_icon_asset`].
pub fn validate_presentation_icon(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.starts_with(SVG_ICON_PREFIX) && !value.starts_with("image:"),
        "bad request: icon assets (svg:, image:) are not accepted for this field"
    );
    let symbol = !value.is_empty()
        && value.len() <= 128
        && !value.starts_with('.')
        && !value.ends_with('.')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'.');
    anyhow::ensure!(
        symbol || is_single_emoji(value),
        "bad request: icon must be an SF Symbol name (lowercase letters, digits, and dots) or one emoji"
    );
    Ok(())
}

/// Validate an icon asset as its owner stores it: `wire` must be
/// `svg:sha256-<64 lowercase hex>`, `bytes` must be a fixed point of
/// [`sanitize_svg_icon`] (the owner sanitizes again and never trusts a
/// client's copy), and the digest must name exactly those bytes.
///
/// Its caller is the icon asset store's put path
/// (`personal_store::blobs::put_blob`).
pub fn validate_presentation_icon_asset(wire: &str, bytes: &[u8]) -> anyhow::Result<()> {
    let digest = wire
        .strip_prefix(SVG_ICON_PREFIX)
        .and_then(|id| id.strip_prefix("sha256-"))
        .filter(|hex| {
            hex.len() == 64 && hex.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        });
    anyhow::ensure!(digest.is_some(), "bad request: icon asset must be svg:sha256-<64 hex>");
    let sanitized = sanitize_svg_icon(bytes)?;
    anyhow::ensure!(
        sanitized.as_bytes() == bytes,
        "bad request: svg icon asset is not in sanitized form"
    );
    anyhow::ensure!(
        svg_icon_wire(&sanitized) == wire,
        "bad request: svg icon asset digest does not match its bytes"
    );
    Ok(())
}

/// Longest accepted emoji icon, in bytes.
const MAX_EMOJI_ICON_BYTES: usize = 32;

fn is_emoji_base(ch: char) -> bool {
    matches!(u32::from(ch),
        0x00A9 | 0x00AE | 0x203C | 0x2049 | 0x2122 | 0x2139
        | 0x2194..=0x21FF | 0x231A..=0x23FF | 0x24C2 | 0x25AA..=0x25FE
        | 0x2600..=0x27BF | 0x2934 | 0x2935 | 0x2B05..=0x2BFF | 0x3030 | 0x303D
        | 0x3297 | 0x3299 | 0x1F000..=0x1FAFF)
}

fn is_regional_indicator(ch: char) -> bool {
    matches!(u32::from(ch), 0x1F1E6..=0x1F1FF)
}

/// One emoji grapheme without a Unicode segmentation table: an emoji base
/// optionally followed by variation selectors, skin tone modifiers, a keycap
/// mark, tag characters, or ZWJ-joined further bases; a flag (two regional
/// indicators); or a keycap sequence (`#`, `*`, or a digit, U+FE0F, U+20E3).
fn is_single_emoji(value: &str) -> bool {
    if value.is_empty() || value.len() > MAX_EMOJI_ICON_BYTES {
        return false;
    }
    let chars = value.chars().collect::<Vec<_>>();
    if chars.iter().any(|ch| ch.is_control() || ch.is_whitespace()) {
        return false;
    }
    if chars.len() == 2 && chars.iter().all(|ch| is_regional_indicator(*ch)) {
        return true;
    }
    if chars.len() >= 2
        && (chars[0].is_ascii_digit() || matches!(chars[0], '#' | '*'))
        && chars[1..].iter().all(|ch| matches!(u32::from(*ch), 0xFE0F | 0x20E3))
        && chars.last() == Some(&'\u{20E3}')
    {
        return true;
    }
    if !is_emoji_base(chars[0]) || is_regional_indicator(chars[0]) {
        return false;
    }
    let mut expect_base = false;
    for ch in &chars[1..] {
        let code = u32::from(*ch);
        if expect_base {
            if !is_emoji_base(*ch) || is_regional_indicator(*ch) {
                return false;
            }
            expect_base = false;
            continue;
        }
        match code {
            0x200D => expect_base = true,
            0xFE0E | 0xFE0F | 0x20E3 | 0x1F3FB..=0x1F3FF | 0xE0020..=0xE007F => {}
            _ => return false,
        }
    }
    !expect_base
}
