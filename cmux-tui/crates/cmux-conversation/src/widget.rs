//! `widget` parts (plans/cmux-next/chat-widgets-DESIGN.md section 3): an
//! agent's message that a client with the named app draws natively from the
//! app's `cmux.chat.widget/1` export, and every other client shows as its
//! `fallback` text (builds from before widgets show its `url`). The same pure
//! rules as the cloud owner will apply; this module checks only the shape.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::link_preview::valid_link_url;

/// Longest `props`, serialized as JSON, in bytes.
pub const MAX_WIDGET_PROPS_BYTES: usize = 16 * 1024;
/// Longest `fallback`, in characters (Unicode scalars).
pub const MAX_WIDGET_FALLBACK_CHARS: usize = 2000;
/// Longest `widget` (an interface name, `cmux.chat.widget/1`), in bytes.
pub const MAX_WIDGET_NAME_BYTES: usize = 128;

/// One widget part.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Widget {
    /// The app id, `publisher/name` (`cmux/pr-card`, `local/customize`).
    pub app: String,
    /// The interface the app implements: `cmux.chat.widget/1`.
    pub widget: String,
    /// The export's input: a JSON object, data only.
    pub props: Value,
    /// Plain text every client without the renderer shows (and search,
    /// notifications, Copy).
    pub fallback: String,
    /// An optional `https` link: what builds from before widgets show.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

/// One app id segment: 1..=64 of `a-z 0-9 - . _`, starting with a letter or digit.
fn valid_segment(segment: &str) -> bool {
    (1..=64).contains(&segment.len())
        && segment.bytes().next().is_some_and(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        && segment.bytes().all(|b| {
            b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'-' | b'.' | b'_')
        })
}

/// `publisher/name`.
pub fn valid_widget_app(app: &str) -> bool {
    app.split_once('/')
        .is_some_and(|(publisher, name)| valid_segment(publisher) && valid_segment(name))
}

/// The shape rules of one widget part.
pub fn valid_widget(widget: &Widget) -> bool {
    let name_ok = !widget.widget.is_empty()
        && widget.widget.len() <= MAX_WIDGET_NAME_BYTES
        && widget.widget.bytes().all(|b| b.is_ascii_graphic());
    let fallback_chars = widget.fallback.chars().count();
    let fallback_ok = widget.fallback.trim().chars().next().is_some()
        && fallback_chars <= MAX_WIDGET_FALLBACK_CHARS
        && !widget.fallback.chars().any(|c| c.is_control() && c != '\n');
    let props_ok = widget.props.is_object()
        && serde_json::to_vec(&widget.props)
            .is_ok_and(|bytes| bytes.len() <= MAX_WIDGET_PROPS_BYTES);
    let url_ok = widget.url.as_deref().is_none_or(|url| {
        url.get(..8).is_some_and(|s| s.eq_ignore_ascii_case("https://")) && valid_link_url(url)
    });
    valid_widget_app(&widget.app) && name_ok && fallback_ok && props_ok && url_ok
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_ids_are_publisher_slash_name() {
        assert!(valid_widget_app("cmux/pr-card"));
        assert!(valid_widget_app("local/customize"));
        assert!(!valid_widget_app("cmux"));
        assert!(!valid_widget_app("cmux/pr/card"));
        assert!(!valid_widget_app("Cmux/pr"));
        assert!(!valid_widget_app("/pr"));
    }
}
