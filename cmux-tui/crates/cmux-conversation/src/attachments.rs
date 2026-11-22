//! Attachment parts (plans/cmux-next/home-messaging.md section 10.1): the
//! same pure rules as the cloud owner (`backend/packages/home-core`
//! `attachments.ts`) and the Swift client (`HomeAttachmentPolicy`). A part
//! names bytes by their SHA-256; the host checks that this conversation holds
//! a record of those bytes with the same type and size before it commits a
//! message that references them.

use crate::types::{DerivedImage, Part};

/// Per file, every type (decimal megabytes, like the cloud owner).
pub const MAX_ATTACHMENT_BYTES: u64 = 100_000_000;
/// A video's poster: at most this size, JPEG or WebP.
pub const MAX_POSTER_BYTES: u64 = 2_000_000;
/// An image's preview: at most this size, JPEG or WebP.
pub const MAX_PREVIEW_IMAGE_BYTES: u64 = 512_000;
/// Longest attachment name, in characters (Unicode scalars).
pub const MAX_ATTACHMENT_NAME_CHARS: usize = 255;
/// Largest width or height of a part.
pub const MAX_DIMENSION: u32 = 100_000;
/// Longest `duration_ms` of a part (24 hours).
pub const MAX_DURATION_MS: u64 = 86_400_000;

/// What an allowed type is, for previews and for which derived image it takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentClass {
    Image,
    Video,
    Audio,
    File,
}

/// A derived image an attachment may carry: a video's poster or an image's preview.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DerivedVariant {
    Poster,
    Preview,
}

impl DerivedVariant {
    /// The only class that takes this variant.
    pub fn class(self) -> AttachmentClass {
        match self {
            Self::Poster => AttachmentClass::Video,
            Self::Preview => AttachmentClass::Image,
        }
    }

    pub fn max_bytes(self) -> u64 {
        match self {
            Self::Poster => MAX_POSTER_BYTES,
            Self::Preview => MAX_PREVIEW_IMAGE_BYTES,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Poster => "poster",
            Self::Preview => "preview",
        }
    }
}

/// The allow list. SVG, HTML and XML are never on it.
pub fn attachment_class(mime_type: &str) -> Option<AttachmentClass> {
    Some(match mime_type {
        "image/jpeg" | "image/png" | "image/gif" | "image/webp" | "image/heic" => {
            AttachmentClass::Image
        }
        "application/pdf" | "text/plain" | "text/markdown" | "text/csv" | "application/json"
        | "application/zip" => AttachmentClass::File,
        "video/mp4" | "video/quicktime" => AttachmentClass::Video,
        "audio/mp4" | "audio/mpeg" | "audio/aac" | "audio/wav" => AttachmentClass::Audio,
        _ => return None,
    })
}

/// A derived image is JPEG or WebP.
pub fn is_derived_image_type(mime_type: &str) -> bool {
    matches!(mime_type, "image/jpeg" | "image/webp")
}

#[rustfmt::skip]
const DENIED_EXTENSIONS: &[&str] = &[
    "exe", "dll", "msi", "msp", "msix", "appx", "bat", "cmd", "com", "scr", "pif", "cpl", "msc",
    "hta", "gadget", "lnk", "reg", "inf", "ps1", "psm1", "vbs", "vbe", "js", "jse", "mjs", "cjs",
    "wsf", "wsh", "jar", "class", "app", "dmg", "pkg", "mpkg", "command", "workflow", "action",
    "scpt", "applescript", "terminal", "tool", "kext", "dylib", "so", "sh", "bash", "zsh", "csh",
    "fish", "ksh", "run", "bin", "elf", "apk", "aab", "ipa", "deb", "rpm", "appimage", "snap",
    "flatpak", "html", "htm", "xhtml", "shtml", "svg", "svgz", "xml", "xsl", "mht", "mhtml",
    "webloc", "url", "desktop", "iso", "img", "vhd", "vhdx",
];

/// True when the name's extension is refused whatever the declared type
/// (executables, installers, scripts, active documents).
pub fn is_denied_name(name: &str) -> bool {
    name.rsplit_once('.').is_some_and(|(_, extension)| {
        DENIED_EXTENSIONS.contains(&extension.to_lowercase().as_str())
    })
}

/// 64 lowercase hex characters.
pub fn is_sha256(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// What JS `trim()` removes (the cloud owner's blank-name rule).
fn is_js_whitespace(character: char) -> bool {
    character.is_whitespace() || character == '\u{FEFF}'
}

/// A display name: 1 to 255 characters, no control characters, line or
/// paragraph separators or path separators, not blank, `.` or `..`.
pub fn valid_attachment_name(name: &str) -> bool {
    let count = name.chars().count();
    count > 0
        && count <= MAX_ATTACHMENT_NAME_CHARS
        && !name.chars().any(|character| {
            character.is_control() || matches!(character, '\u{2028}' | '\u{2029}' | '/' | '\\')
        })
        && !name.chars().all(is_js_whitespace)
        && name != "."
        && name != ".."
}

/// Why an upload or a part was refused, as the cloud owner names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttachmentReject {
    /// Malformed hash, name, size, dimensions or duration.
    Invalid,
    /// Not on the allow list, or a denied extension.
    TypeRefused,
    /// Over the class's size cap.
    TooLarge,
    /// A poster on a non-video or a preview on a non-image.
    DerivedRefused(DerivedVariant),
}

impl AttachmentReject {
    pub fn code(self) -> &'static str {
        match self {
            Self::Invalid => "validation_invalid",
            Self::TypeRefused => "type_refused",
            Self::TooLarge => "too_large",
            Self::DerivedRefused(DerivedVariant::Poster) => "poster_refused",
            Self::DerivedRefused(DerivedVariant::Preview) => "preview_refused",
        }
    }
}

impl std::fmt::Display for AttachmentReject {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.code())
    }
}

impl std::error::Error for AttachmentReject {}

/// The upload rules for one file: hash, size, type, name, dimensions and duration.
pub fn validate_attachment_meta(
    hash: &str,
    mime_type: &str,
    byte_count: u64,
    name: &str,
    width: Option<u32>,
    height: Option<u32>,
    duration_ms: Option<u64>,
) -> Result<AttachmentClass, AttachmentReject> {
    let dimension_ok = |value: Option<u32>| value.is_none_or(|v| (1..=MAX_DIMENSION).contains(&v));
    if !is_sha256(hash)
        || byte_count == 0
        || !valid_attachment_name(name)
        || !dimension_ok(width)
        || !dimension_ok(height)
        || duration_ms.is_some_and(|duration| duration > MAX_DURATION_MS)
    {
        return Err(AttachmentReject::Invalid);
    }
    let class = attachment_class(mime_type).ok_or(AttachmentReject::TypeRefused)?;
    if is_denied_name(name) {
        return Err(AttachmentReject::TypeRefused);
    }
    if byte_count > MAX_ATTACHMENT_BYTES {
        return Err(AttachmentReject::TooLarge);
    }
    Ok(class)
}

/// The rules for a derived image declared on an attachment of `class`.
pub fn validate_derived(
    image: &DerivedImage,
    class: AttachmentClass,
    variant: DerivedVariant,
) -> Result<(), AttachmentReject> {
    if class != variant.class() {
        return Err(AttachmentReject::DerivedRefused(variant));
    }
    if !is_sha256(&image.hash) || image.byte_count == 0 {
        return Err(AttachmentReject::Invalid);
    }
    if !is_derived_image_type(&image.mime_type) {
        return Err(AttachmentReject::TypeRefused);
    }
    if image.byte_count > variant.max_bytes() {
        return Err(AttachmentReject::TooLarge);
    }
    Ok(())
}

/// The shape rules of one attachment part (the cloud `cleanAttachmentPart`).
pub fn valid_attachment_part(part: &Part) -> bool {
    let Part::Attachment {
        hash,
        name,
        mime_type,
        byte_count,
        width,
        height,
        duration_ms,
        poster,
        preview,
    } = part
    else {
        return false;
    };
    let Ok(class) =
        validate_attachment_meta(hash, mime_type, *byte_count, name, *width, *height, *duration_ms)
    else {
        return false;
    };
    let derived_ok = |image: &Option<DerivedImage>, variant| {
        image.as_ref().is_none_or(|image| validate_derived(image, class, variant).is_ok())
    };
    derived_ok(poster, DerivedVariant::Poster) && derived_ok(preview, DerivedVariant::Preview)
}
