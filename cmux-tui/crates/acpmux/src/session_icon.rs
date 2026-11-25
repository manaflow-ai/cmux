//! A session's own icon, set by the agent or the person (`acpmux icon`, `cmux agent icon`): what
//! the tab, the sidebar row, the chat lists, the chat header and a message's sender line draw for
//! the chat in place of its harness mark (Leo, 2026-11-22: "MAYBE YOU GUYS SHUOLD BE ABLE TO SET
//! CUSTOM ICONS FOR YOURSELVES IN THE TABS. SYMBOLS, SVGS, EMOJIS, FAVICONS, WHATEVER").
//!
//! It has the shape of a harness's `iconSpec` (`config/harness_icon.rs`, `kind` plus its fields,
//! `source: "session"`), so every client draws it with the renderer it already has for those.
//! Clients never parse a raw value: the daemon stores the spec and sends it on the summary.
//!
//! An image rides every summary of the chat, so it is small ([`MAX_IMAGE_BYTES`]); a favicon or
//! an SVG mark fits. The CLI reads a file or fetches a URL and sends the bytes.

use base64::Engine as _;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::config::harness_icon::{self, IconValue};

/// Largest image accepted, in bytes before base64 (about 8 KiB once encoded). It travels on each
/// of the chat's summaries.
pub const MAX_IMAGE_BYTES: usize = 6 * 1024;

/// The icon clients draw for one chat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SessionIcon {
    /// An agent mark id from design/agent-icons (`claude`, `gemini`, ...).
    Brand {
        brand: String,
        #[serde(default = "source")]
        source: String,
    },
    /// One emoji.
    Emoji {
        text: String,
        #[serde(default = "source")]
        source: String,
    },
    /// An SF Symbol; `text` and `hue` are the monogram a client that cannot draw it shows.
    Symbol {
        name: String,
        text: String,
        hue: u16,
        #[serde(default = "source")]
        source: String,
    },
    /// An SVG, PNG, ICO or JPEG, base64, so a page draws it with no file or network access.
    Image {
        mime: String,
        data: String,
        #[serde(default = "source")]
        source: String,
    },
}

fn source() -> String {
    "session".to_owned()
}

impl SessionIcon {
    /// The icon `raw` names (one emoji, an SF Symbol name or `sf:NAME`, an agent mark id); `id`
    /// and `name` pick a symbol's monogram fallback. A file or URL is the CLI's to read
    /// ([`SessionIcon::image`]).
    pub fn parse(raw: &str, id: &str, name: &str) -> Result<Self, String> {
        let value = raw.trim();
        // An image the CLI read, sent as a data URL.
        if let Some(rest) = value.strip_prefix("data:") {
            let (mime, data) = rest
                .split_once(";base64,")
                .ok_or_else(|| "a data URL icon is base64 (data:MIME;base64,...)".to_owned())?;
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(data.trim())
                .map_err(|e| format!("the icon's base64 does not decode: {e}"))?;
            return Self::image(mime, &bytes);
        }
        match IconValue::parse(value)? {
            IconValue::Brand(brand) => Ok(Self::Brand { brand, source: source() }),
            IconValue::Emoji(text) => Ok(Self::Emoji { text, source: source() }),
            IconValue::Symbol(symbol) => Ok(Self::Symbol {
                name: symbol,
                text: harness_icon::monogram(name),
                hue: harness_icon::hue(id),
                source: source(),
            }),
            IconValue::Glyph(glyph) => Ok(Self::Symbol {
                name: if glyph == "terminal" { "terminal".into() } else { "sparkles".into() },
                text: harness_icon::monogram(name),
                hue: harness_icon::hue(id),
                source: source(),
            }),
            IconValue::File(file) => Err(format!(
                "{file:?} is a file: `acpmux icon` reads it and sends its bytes (a daemon reads no \
                 path a client names)"
            )),
        }
    }

    /// An image icon of `bytes` of type `mime`, checked as a harness icon file is.
    pub fn image(mime: &str, bytes: &[u8]) -> Result<Self, String> {
        let mime = mime.trim().to_ascii_lowercase();
        if bytes.len() > MAX_IMAGE_BYTES {
            return Err(format!(
                "the image is {} bytes; an icon is at most {MAX_IMAGE_BYTES} (it rides every row \
                 of the chat): use a favicon-sized PNG or a small SVG",
                bytes.len()
            ));
        }
        match mime.as_str() {
            "image/svg+xml" | "image/png" => harness_icon::check_image_bytes(&mime, bytes)?,
            "image/x-icon" | "image/vnd.microsoft.icon" => {
                if !bytes.starts_with(&[0, 0, 1, 0]) {
                    return Err("the file is not an ICO image".into());
                }
            }
            "image/jpeg" => {
                if !bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
                    return Err("the file is not a JPEG image".into());
                }
            }
            other => {
                return Err(format!("an icon image is SVG, PNG, ICO or JPEG, not {other:?}"));
            }
        }
        let mime = if mime == "image/vnd.microsoft.icon" { "image/x-icon".into() } else { mime };
        Ok(Self::Image {
            mime,
            data: base64::engine::general_purpose::STANDARD.encode(bytes),
            source: source(),
        })
    }

    /// The image type a file or URL path names by its extension.
    pub fn mime_of(path: &str) -> Option<&'static str> {
        let lower = path.to_ascii_lowercase();
        let lower = lower.split(['?', '#']).next().unwrap_or_default();
        [
            (".svg", "image/svg+xml"),
            (".png", "image/png"),
            (".ico", "image/x-icon"),
            (".jpg", "image/jpeg"),
            (".jpeg", "image/jpeg"),
        ]
        .into_iter()
        .find(|(ext, _)| lower.ends_with(ext))
        .map(|(_, mime)| mime)
    }

    /// The image type `bytes` hold, from their first bytes, for a URL that names none.
    pub fn sniff(bytes: &[u8]) -> Option<&'static str> {
        if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            Some("image/png")
        } else if bytes.starts_with(&[0, 0, 1, 0]) {
            Some("image/x-icon")
        } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
            Some("image/jpeg")
        } else if std::str::from_utf8(bytes.get(..bytes.len().min(512)).unwrap_or(bytes))
            .is_ok_and(|head| head.to_ascii_lowercase().contains("<svg"))
        {
            Some("image/svg+xml")
        } else {
            None
        }
    }

    /// The value a person reads back (`acpmux icon` with no value, `ls`): the emoji, the symbol
    /// name, the mark id, or the image's type and size.
    pub fn describe(&self) -> String {
        match self {
            Self::Brand { brand, .. } => brand.clone(),
            Self::Emoji { text, .. } => text.clone(),
            Self::Symbol { name, .. } => format!("sf:{name}"),
            Self::Image { mime, data, .. } => format!("{mime} ({} bytes base64)", data.len()),
        }
    }

    /// Whether it is small enough for a bounded list row (`hub/list_tee`): every kind but an
    /// image, whose base64 a row's text cut would break. A list row's reader gets the image from
    /// the chat's own summary.
    pub fn fits_a_row(&self) -> bool {
        !matches!(self, Self::Image { .. })
    }
}

/// The words that clear an icon: `acpmux icon @ none`.
pub fn clears(raw: &str) -> bool {
    matches!(raw.trim().to_ascii_lowercase().as_str(), "" | "none" | "clear" | "reset" | "-")
}

#[cfg(test)]
#[path = "session_icon_tests.rs"]
mod tests;
