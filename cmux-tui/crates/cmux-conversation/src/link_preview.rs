//! `link_preview` parts (iMessage-style sender-side previews): the sender
//! fetches a page's title, site name and image and sends them as a part;
//! receivers render only from the part. The same pure rules as the cloud
//! owner (`backend/packages/home-core` `link-preview.ts`).
//!
//! The image is an ordinary attachment record the sender uploaded to this
//! conversation (`conversation-attachment-upload`): JPEG or WebP, at most
//! [`MAX_PREVIEW_IMAGE_BYTES`]. The host checks that record like an
//! `attachment` part's hash; this module checks only the shape.

use crate::attachments::{MAX_PREVIEW_IMAGE_BYTES, is_derived_image_type, is_sha256};
use crate::types::Part;

/// Longest URL, in UTF-8 bytes.
pub const MAX_LINK_URL_BYTES: usize = 2048;
/// Longest title, in characters (Unicode scalars).
pub const MAX_LINK_TITLE_CHARS: usize = 300;
/// Longest site name, in characters (a DNS name's length).
pub const MAX_LINK_SITE_CHARS: usize = 253;

/// An absolute `http://` or `https://` URL (scheme case-insensitive) of
/// 1..=2048 bytes with a non-empty authority, no user info, and no
/// whitespace, control characters or backslashes anywhere. Deliberately a
/// plain rule, not a full URL parser, so the cloud owner applies exactly
/// the same one.
pub fn valid_link_url(url: &str) -> bool {
    if url.is_empty() || url.len() > MAX_LINK_URL_BYTES {
        return false;
    }
    if url
        .chars()
        .any(|character| character.is_control() || character.is_whitespace() || character == '\\')
    {
        return false;
    }
    let lower = url.get(..8).unwrap_or(url).to_ascii_lowercase();
    let rest = if lower.starts_with("https://") {
        &url[8..]
    } else if lower.starts_with("http://") {
        &url[7..]
    } else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    !authority.is_empty() && !authority.contains('@')
}

/// Optional display text: 1..=`max_chars` characters, no control characters.
fn valid_label(value: Option<&str>, max_chars: usize) -> bool {
    value.is_none_or(|value| {
        let count = value.chars().count();
        count > 0 && count <= max_chars && !value.chars().any(char::is_control)
    })
}

/// The shape rules of one `link_preview` part.
pub fn valid_link_preview_part(part: &Part) -> bool {
    let Part::LinkPreview { url, title, site, image } = part else {
        return false;
    };
    let image_ok = image.as_ref().is_none_or(|image| {
        is_sha256(&image.hash)
            && is_derived_image_type(&image.mime_type)
            && (1..=MAX_PREVIEW_IMAGE_BYTES).contains(&image.byte_count)
    });
    valid_link_url(url)
        && valid_label(title.as_deref(), MAX_LINK_TITLE_CHARS)
        && valid_label(site.as_deref(), MAX_LINK_SITE_CHARS)
        && image_ok
}
