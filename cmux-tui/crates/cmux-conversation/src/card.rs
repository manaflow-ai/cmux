//! `card` parts: what an agent shows beside its words (issue 25830). A live
//! browser or computer card (the step it is on and a screenshot), a Secure
//! Store sign-in card, and suggested next steps the person sends with a tap.
//! The same pure rules as the cloud owner (`backend/packages/home-core`
//! `card.ts`).
//!
//! A browser card's screenshot is an ordinary attachment record the sender
//! uploaded to this conversation; the host checks that record like an
//! `attachment` part's hash, this module checks only the shape.

use serde::{Deserialize, Serialize};

use crate::attachments::is_sha256;
use crate::link_preview::valid_link_url;

/// Longest browser step, in characters (Unicode scalars).
pub const MAX_CARD_STEP_CHARS: usize = 200;
/// Longest sign-in site, in characters (a DNS name's length).
pub const MAX_CARD_SITE_CHARS: usize = 253;
/// Most suggested next steps on one card.
pub const MAX_CARD_CHOICES: usize = 3;
/// Longest suggested next step, in characters.
pub const MAX_CARD_CHOICE_CHARS: usize = 120;
/// Largest browser screenshot (4 MiB).
pub const MAX_CARD_IMAGE_BYTES: u64 = 4 * 1024 * 1024;
/// Largest screenshot width or height.
pub const MAX_CARD_IMAGE_DIMENSION: u32 = 16_384;
/// Longest machine id in a `machine:<id>` target.
const MAX_MACHINE_ID_CHARS: usize = 128;

/// What drives a browser card: a web page, or a whole computer's desktop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CardSurface {
    Browser,
    Computer,
}

/// A browser card's screenshot: an attachment record of this conversation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CardImage {
    pub hash: String,
    pub mime_type: String,
    pub byte_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
}

/// One card, tagged by `kind` inside its part (`{"type":"card","kind":...}`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Card {
    /// The agent drives a browser or a computer: the step it is on, the
    /// latest screenshot, and what "Open browser" opens. The agent edits the
    /// one card of a turn as it goes; `live` is false once the turn ended.
    Browser {
        surface: CardSurface,
        step: String,
        #[serde(default)]
        live: bool,
        /// `browser:right` (the browser beside the Home chat on the Chief's
        /// Mac) or `machine:<id>` (a Cloud machine's desktop).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        target: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        image: Option<CardImage>,
    },
    /// A site needs a sign-in: the person adds it to the Secure Store on
    /// their own device; the password never enters the conversation.
    SignIn {
        site: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<String>,
    },
    /// Suggested next steps under a reply: a tap sends one as the person.
    NextSteps { choices: Vec<String> },
}

impl Card {
    /// The card as one line of text, for readers that show no cards (a
    /// transcript, a search, an older client's preview).
    pub fn text(&self) -> String {
        match self {
            Self::Browser { surface, step, .. } => {
                let title = match surface {
                    CardSurface::Browser => "Browser",
                    CardSurface::Computer => "Computer",
                };
                format!("{title}: {step}")
            }
            Self::SignIn { site, .. } => format!("Secure Store: sign in to {site}"),
            Self::NextSteps { choices } => choices
                .iter()
                .map(|choice| format!("→ {choice}"))
                .collect::<Vec<_>>()
                .join("\n"),
        }
    }

    /// The words a search matches: a browser card's step, a sign-in card's
    /// site, each next step.
    pub fn search_words(&self) -> Vec<&str> {
        match self {
            Self::Browser { step, .. } => vec![step.as_str()],
            Self::SignIn { site, .. } => vec![site.as_str()],
            Self::NextSteps { choices } => choices.iter().map(String::as_str).collect(),
        }
    }

    /// The screenshot record this card references, if any.
    pub fn image(&self) -> Option<&CardImage> {
        match self {
            Self::Browser { image, .. } => image.as_ref(),
            _ => None,
        }
    }
}

/// 1..=`max_chars` characters, no control characters.
fn valid_label(value: &str, max_chars: usize) -> bool {
    let count = value.chars().count();
    count > 0 && count <= max_chars && !value.chars().any(char::is_control)
}

/// A lowercase DNS name with at least one dot: `linkedin.com`.
pub fn valid_card_site(site: &str) -> bool {
    !site.is_empty()
        && site.len() <= MAX_CARD_SITE_CHARS
        && site.contains('.')
        && !site.starts_with(['.', '-'])
        && !site.ends_with(['.', '-'])
        && !site.contains("..")
        && site.bytes().all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'.' | b'-'))
}

/// `browser:right` or `machine:<id>` with an id of `[A-Za-z0-9_-]{1,128}`.
pub fn valid_card_target(target: &str) -> bool {
    if target == "browser:right" {
        return true;
    }
    target.strip_prefix("machine:").is_some_and(|id| {
        !id.is_empty()
            && id.len() <= MAX_MACHINE_ID_CHARS
            && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    })
}

fn valid_card_image(image: &CardImage) -> bool {
    is_sha256(&image.hash)
        && matches!(image.mime_type.as_str(), "image/png" | "image/jpeg" | "image/webp")
        && (1..=MAX_CARD_IMAGE_BYTES).contains(&image.byte_count)
        && image.width.is_none_or(|w| (1..=MAX_CARD_IMAGE_DIMENSION).contains(&w))
        && image.height.is_none_or(|h| (1..=MAX_CARD_IMAGE_DIMENSION).contains(&h))
}

/// The shape rules of one card.
pub fn valid_card(card: &Card) -> bool {
    match card {
        Card::Browser { step, target, url, image, .. } => {
            valid_label(step, MAX_CARD_STEP_CHARS)
                && target.as_deref().is_none_or(valid_card_target)
                && url.as_deref().is_none_or(valid_link_url)
                && image.as_ref().is_none_or(valid_card_image)
        }
        Card::SignIn { site, url } => {
            valid_card_site(site) && url.as_deref().is_none_or(valid_link_url)
        }
        Card::NextSteps { choices } => {
            (1..=MAX_CARD_CHOICES).contains(&choices.len())
                && choices.iter().all(|choice| valid_label(choice, MAX_CARD_CHOICE_CHARS))
                && choices
                    .iter()
                    .enumerate()
                    .all(|(index, choice)| !choices[..index].contains(choice))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::Part;
    use serde_json::json;

    fn part(value: serde_json::Value) -> Part {
        serde_json::from_value(value).expect("part")
    }

    fn card(value: serde_json::Value) -> Card {
        match part(value) {
            Part::Card(card) => card,
            other => panic!("not a card: {other:?}"),
        }
    }

    #[test]
    fn browser_card_round_trips_with_its_screenshot() {
        let value = json!({"type": "card", "kind": "browser", "surface": "browser",
            "step": "Returning to LinkedIn Messaging", "live": true, "target": "browser:right",
            "url": "https://www.linkedin.com/messaging/",
            "image": {"hash": "a".repeat(64), "mime_type": "image/png", "byte_count": 1000,
                      "width": 1280, "height": 800}});
        let parsed = part(value.clone());
        assert!(matches!(&parsed, Part::Card(card) if valid_card(card)));
        assert_eq!(serde_json::to_value(&parsed).unwrap(), value);
    }

    #[test]
    fn sign_in_and_next_steps_round_trip() {
        for value in [
            json!({"type": "card", "kind": "sign_in", "site": "linkedin.com",
                   "url": "https://www.linkedin.com/login"}),
            json!({"type": "card", "kind": "next_steps",
                   "choices": ["Try sending the Kernel update again"]}),
        ] {
            let parsed = part(value.clone());
            assert!(matches!(&parsed, Part::Card(card) if valid_card(card)));
            assert_eq!(serde_json::to_value(&parsed).unwrap(), value);
        }
    }

    #[test]
    fn an_unknown_kind_is_not_a_card() {
        let parsed = part(json!({"type": "card", "kind": "poll", "choices": ["a"]}));
        assert!(matches!(parsed, Part::Unknown(_)));
    }

    #[test]
    fn shape_rules_refuse_bad_cards() {
        let bad = [
            json!({"type": "card", "kind": "browser", "surface": "browser", "step": ""}),
            json!({"type": "card", "kind": "browser", "surface": "browser", "step": "a\nb"}),
            json!({"type": "card", "kind": "browser", "surface": "computer", "step": "x",
                   "target": "machine:"}),
            json!({"type": "card", "kind": "browser", "surface": "computer", "step": "x",
                   "target": "file:/etc"}),
            json!({"type": "card", "kind": "browser", "surface": "browser", "step": "x",
                   "url": "javascript:alert(1)"}),
            json!({"type": "card", "kind": "browser", "surface": "browser", "step": "x",
                   "image": {"hash": "a".repeat(64), "mime_type": "image/gif", "byte_count": 1,
                             "width": 1, "height": 1}}),
            json!({"type": "card", "kind": "browser", "surface": "browser", "step": "x",
                   "image": {"hash": "a".repeat(64), "mime_type": "image/png",
                             "byte_count": MAX_CARD_IMAGE_BYTES + 1, "width": 1, "height": 1}}),
            json!({"type": "card", "kind": "sign_in", "site": "LinkedIn.com"}),
            json!({"type": "card", "kind": "sign_in", "site": "localhost"}),
            json!({"type": "card", "kind": "sign_in", "site": "a..b"}),
            json!({"type": "card", "kind": "next_steps", "choices": []}),
            json!({"type": "card", "kind": "next_steps", "choices": ["a", "b", "c", "d"]}),
            json!({"type": "card", "kind": "next_steps", "choices": ["a", "a"]}),
            json!({"type": "card", "kind": "next_steps", "choices": ["x".repeat(121)]}),
        ];
        for value in bad {
            assert!(!valid_card(&card(value.clone())), "accepted {value}");
        }
    }

    #[test]
    fn targets_and_sites() {
        assert!(valid_card_target("browser:right"));
        assert!(valid_card_target("machine:m_123-abc"));
        assert!(!valid_card_target("browser:left"));
        assert!(!valid_card_target("machine:a/b"));
        assert!(valid_card_site("www.linkedin.com"));
        assert!(!valid_card_site("-a.com"));
        assert!(!valid_card_site("a.com."));
    }

    #[test]
    fn text_fallbacks() {
        let browser = card(json!({"type": "card", "kind": "browser", "surface": "computer",
                                  "step": "Opening Settings"}));
        assert_eq!(browser.text(), "Computer: Opening Settings");
        let sign_in = card(json!({"type": "card", "kind": "sign_in", "site": "linkedin.com"}));
        assert_eq!(sign_in.text(), "Secure Store: sign in to linkedin.com");
        let steps = card(json!({"type": "card", "kind": "next_steps", "choices": ["a", "b"]}));
        assert_eq!(steps.text(), "→ a\n→ b");
    }
}
