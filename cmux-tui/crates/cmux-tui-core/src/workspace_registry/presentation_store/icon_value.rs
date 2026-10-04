//! The one icon value of every entity with an icon: workspaces, screens and
//! saved screen group members, rooms, browser profiles and workspace status
//! entries (plans/cmux-next/data-model.md "Shared appearance shape").
//!
//! - an SF Symbol name such as `terminal`, `folder.fill` or `0.circle`;
//! - exactly one emoji grapheme;
//! - `image:sha256-<64 lowercase hex>`: a raster asset (PNG, JPEG or WebP)
//!   in the personal blob store (`icon-assets-v1`);
//! - `svg:sha256-<64 lowercase hex>`: a sanitized SVG asset there.
//!
//! This check is the format only. A setter also requires a named asset to
//! exist with the matching media type, in its own transaction
//! (`personal_store::blobs::require_icon_asset`).

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
        (IconAssetKind::Svg, value.strip_prefix("svg:")?)
    };
    let digest = rest.strip_prefix("sha256-")?;
    is_sha256_hex(digest).then_some(IconAssetRef { kind, digest })
}

/// Exactly 64 lowercase hex digits.
pub fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// An SF Symbol name, one emoji, or an asset reference (see the module
/// documentation).
pub fn validate_presentation_icon(value: &str) -> anyhow::Result<()> {
    let symbol = !value.is_empty()
        && value.len() <= 128
        && !value.starts_with('.')
        && !value.ends_with('.')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'.');
    anyhow::ensure!(
        symbol || is_single_emoji(value) || parse_icon_asset(value).is_some(),
        "bad request: icon must be an SF Symbol name (lowercase letters, digits, and dots), one emoji, image:sha256-<hex>, or svg:sha256-<hex>"
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
