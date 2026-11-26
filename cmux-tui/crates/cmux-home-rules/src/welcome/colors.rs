//! Each chat's own bubble colours (`HomeChatColorStore`) and the hex text they are written in
//! (`HomeColor(hex:)`, `HomeColor.hex`). Swift keeps the defaults data and draws; colours travel as
//! canonical hex text.

use crate::ops::{OpError, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

pub const KEY: &str = "cmux.home.chatColors";
pub const ROLES: [&str; 4] = ["sent", "sentText", "received", "receivedText"];

/// Swift's `trimmingCharacters(in: .whitespaces)`: spaces and tabs, not line breaks.
pub fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|c: char| {
        c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
    })
}

/// `HomeColor(hex:)` then `.hex`: `#RRGGBB`, `RRGGBB`, `#RRGGBBAA` or `#RGB` to canonical upper-case
/// `#RRGGBB`, with `AA` only when not opaque; `None` for anything else.
pub fn canonical_hex(text: &str) -> Option<String> {
    let mut text = trim_spaces(text);
    if let Some(rest) = text.strip_prefix('#') {
        text = rest;
    }
    let expanded: String;
    let text = if text.chars().count() == 3 {
        expanded = text.chars().flat_map(|c| [c, c]).collect();
        expanded.as_str()
    } else {
        text
    };
    let count = text.chars().count();
    if count != 6 && count != 8 {
        return None;
    }
    let value = u64::from_str_radix(text, 16).ok()?;
    let bytes = if count == 8 { value } else { (value << 8) | 0xFF };
    let byte = |shift: u32| (bytes >> shift) & 0xFF;
    let rgb = format!("#{:02X}{:02X}{:02X}", byte(24), byte(16), byte(8));
    Some(if byte(0) == 0xFF { rgb } else { format!("{rgb}{:02X}", byte(0)) })
}

/// `HomeBubbleColors`: each role's colour as canonical hex, or none (the theme's).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BubbleColors {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sent_text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub received: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub received_text: Option<String>,
}

impl BubbleColors {
    pub fn is_empty(&self) -> bool {
        self.sent.is_none()
            && self.sent_text.is_none()
            && self.received.is_none()
            && self.received_text.is_none()
    }

    fn role_mut(&mut self, role: &str) -> &mut Option<String> {
        match role {
            "sent" => &mut self.sent,
            "sentText" => &mut self.sent_text,
            "received" => &mut self.received,
            _ => &mut self.received_text,
        }
    }

    fn role(&self, role: &str) -> Option<&String> {
        match role {
            "sent" => self.sent.as_ref(),
            "sentText" => self.sent_text.as_ref(),
            "received" => self.received.as_ref(),
            _ => self.received_text.as_ref(),
        }
    }

    /// Every colour put in canonical form; one that does not parse makes the whole value fail, as
    /// `HomeColor`'s decoder does.
    fn canonical(&self) -> Option<BubbleColors> {
        let fix = |v: &Option<String>| -> Option<Option<String>> {
            match v {
                None => Some(None),
                Some(text) => canonical_hex(text).map(Some),
            }
        };
        Some(BubbleColors {
            sent: fix(&self.sent)?,
            sent_text: fix(&self.sent_text)?,
            received: fix(&self.received)?,
            received_text: fix(&self.received_text)?,
        })
    }

    /// `HomeBubbleColors.hexSummary`.
    pub fn hex_summary(&self) -> String {
        ROLES
            .iter()
            .filter_map(|role| self.role(role).map(|hex| format!("{role}={hex}")))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

pub type Chats = BTreeMap<String, BubbleColors>;

/// `HomeChatColorStore.init`: the stored JSON, or nothing when any of it does not decode.
pub fn load(stored: Option<&str>) -> Chats {
    let Some(text) = stored else { return Chats::new() };
    let Ok(raw) = serde_json::from_str::<Chats>(text) else { return Chats::new() };
    raw.into_iter()
        .map(|(k, v)| v.canonical().map(|c| (k, c)))
        .collect::<Option<Chats>>()
        .unwrap_or_default()
}

/// `HomeChatColorStore.set`: the new chats, and whether they changed (and so are written).
pub fn set(chats: &Chats, conversation: &str, colors: BubbleColors) -> (Chats, bool) {
    let current = chats.get(conversation).cloned().unwrap_or_default();
    if current == colors {
        return (chats.clone(), false);
    }
    let mut next = chats.clone();
    if colors.is_empty() {
        next.remove(conversation);
    } else {
        next.insert(conversation.to_string(), colors);
    }
    (next, true)
}

/// `HomeChatColorsRefusal`: a role's value that is not a colour.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Refusal {
    pub role: String,
    pub value: String,
}

/// `HomeChatColorStore.apply(_:reset:to:)`: `Ok(None)` when nothing was named, else the new chats.
pub fn apply(
    chats: &Chats,
    values: &BTreeMap<String, String>,
    reset: bool,
    conversation: &str,
) -> Result<Option<(Chats, bool)>, Refusal> {
    let mut colors = if reset {
        BubbleColors::default()
    } else {
        chats.get(conversation).cloned().unwrap_or_default()
    };
    let mut named = reset;
    for role in ROLES {
        let Some(raw) = values.get(role) else { continue };
        let text = trim_spaces(raw);
        if text.is_empty() {
            continue;
        }
        named = true;
        if text == "default" || text == "theme" {
            *colors.role_mut(role) = None;
            continue;
        }
        let Some(hex) = canonical_hex(text) else {
            return Err(Refusal { role: role.to_string(), value: text.to_string() });
        };
        *colors.role_mut(role) = Some(hex);
    }
    if !named {
        return Ok(None);
    }
    Ok(Some(set(chats, conversation, colors)))
}

/// `HomeChatColorStore.colors(fromHexes:)`: each role that parses.
pub fn from_hexes(hexes: &BTreeMap<String, String>) -> BubbleColors {
    let get = |role: &str| hexes.get(role).and_then(|h| canonical_hex(h));
    BubbleColors {
        sent: get("sent"),
        sent_text: get("sentText"),
        received: get("received"),
        received_text: get("receivedText"),
    }
}

fn write(chats: &Chats) -> Value {
    json!({"key": KEY, "value": serde_json::to_string(chats).unwrap_or_else(|_| "{}".into())})
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct StoreRequest {
    chats: Chats,
    conversation: String,
    colors: BubbleColors,
    values: BTreeMap<String, String>,
    reset: bool,
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "colorHex" => {
            #[derive(Deserialize)]
            struct Req {
                hex: String,
            }
            let req: Req = parse(request)?;
            reply(&json!({"hex": canonical_hex(&req.hex)}))
        }
        "chatColorsLoad" => {
            #[derive(Default, Deserialize)]
            #[serde(default)]
            struct Req {
                stored: Option<String>,
            }
            let req: Req = parse(request)?;
            reply(&json!({"key": KEY, "chats": load(req.stored.as_deref())}))
        }
        "chatColorsSet" => {
            let req: StoreRequest = parse(request)?;
            let colors = req.colors.canonical().ok_or_else(|| OpError::Invalid("colors".into()))?;
            let (chats, changed) = set(&req.chats, &req.conversation, colors);
            reply(
                &json!({"chats": chats, "changed": changed, "write": changed.then(|| write(&chats))}),
            )
        }
        "chatColorsApply" => {
            let req: StoreRequest = parse(request)?;
            match apply(&req.chats, &req.values, req.reset, &req.conversation) {
                Err(refusal) => reply(&json!({"applied": false, "refusal": refusal})),
                Ok(None) => reply(&json!({"applied": false, "refusal": null, "chats": req.chats})),
                Ok(Some((chats, changed))) => reply(&json!({
                    "applied": true,
                    "refusal": null,
                    "chats": chats,
                    "changed": changed,
                    "write": changed.then(|| write(&chats)),
                })),
            }
        }
        "chatColorsFromHexes" => {
            #[derive(Default, Deserialize)]
            #[serde(default)]
            struct Req {
                hexes: BTreeMap<String, String>,
            }
            let req: Req = parse(request)?;
            reply(&json!({"colors": from_hexes(&req.hexes)}))
        }
        "chatColorsSummary" => {
            #[derive(Default, Deserialize)]
            #[serde(default)]
            struct Req {
                colors: BubbleColors,
            }
            let req: Req = parse(request)?;
            let colors = req.colors.canonical().ok_or_else(|| OpError::Invalid("colors".into()))?;
            reply(&json!({"summary": colors.hex_summary()}))
        }
        _ => Err(OpError::Unknown),
    }
}
