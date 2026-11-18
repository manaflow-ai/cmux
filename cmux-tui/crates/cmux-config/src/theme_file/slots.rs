//! A theme file's `"slots"`: the variant each theme slot draws
//! (`schemas/theme/slots.json`), as
//! `{"slots": {"chat.thinkingIndicator": "pulse"}}`.
//!
//! Each entry is the setting `appearance.slots.<slot id>` (a choice of the
//! slot's variants), so `cmux settings set`, the palette and the chat page
//! read the same value the file writes. Every entry is checked on its own
//! against slots.json: an unknown slot, or a variant the slot does not ship,
//! is dropped with a diagnostic naming that slot, and the file's other slots
//! and settings still apply. The chat then draws the slot's default.

use std::sync::OnceLock;

use serde_json::Value;

use super::Reader;
use crate::keypath::key_path;

/// The theme file key that holds the slot choices.
pub const KEY: &str = "slots";
/// The settings prefix of a slot's variant: `appearance.slots.<slot id>`.
pub const SETTING_PREFIX: &str = "appearance.slots.";

const SLOTS_JSON: &str = include_str!("../../../../../schemas/theme/slots.json");

/// One slot of slots.json: its id and its variant ids in file order.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SlotSpec {
    pub id: String,
    pub default_variant: String,
    pub variants: Vec<String>,
}

/// The slots cmux ships (schemas/theme/slots.json), in file order.
pub fn shipped() -> &'static [SlotSpec] {
    static SLOTS: OnceLock<Vec<SlotSpec>> = OnceLock::new();
    SLOTS.get_or_init(|| parse(SLOTS_JSON))
}

/// The slots in a slots.json text; a slot missing its id or variants is skipped.
pub fn parse(text: &str) -> Vec<SlotSpec> {
    let Ok(root) = serde_json::from_str::<Value>(text) else { return Vec::new() };
    let Some(slots) = root.get("slots").and_then(Value::as_array) else { return Vec::new() };
    slots
        .iter()
        .filter_map(|slot| {
            let id = slot.get("id")?.as_str()?.to_string();
            let default_variant = slot.get("defaultVariant")?.as_str()?.to_string();
            let variants = slot
                .get("variants")?
                .as_array()?
                .iter()
                .filter_map(|variant| variant.get("id")?.as_str().map(str::to_string))
                .collect();
            Some(SlotSpec { id, default_variant, variants })
        })
        .collect()
}

/// The setting that holds `slot`'s variant.
pub fn setting_key(slot: &str) -> String {
    format!("{SETTING_PREFIX}{slot}")
}

impl Reader<'_> {
    /// Reads the file's `"slots"` object, one slot at a time.
    pub(super) fn read_slots(&mut self, written: &Value) {
        let Value::Object(entries) = written else {
            return self.refuse(
                KEY,
                Some(written),
                "expected an object of slot ids and variant ids, such as {\"chat.thinkingIndicator\": \"pulse\"}",
            );
        };
        let mut ids: Vec<&String> = entries.keys().collect();
        ids.sort();
        for id in ids {
            self.read_slot(id, &entries[id]);
        }
    }

    fn read_slot(&mut self, id: &str, written: &Value) {
        let path = format!("{KEY}.{id}");
        let line = super::line_of_key(self.text, id);
        let Some(slot) = shipped().iter().find(|slot| slot.id == id) else {
            let known: Vec<&str> = shipped().iter().map(|slot| slot.id.as_str()).collect();
            let message = format!("no theme slot {id}; expected one of {}", known.join(", "));
            return self.refuse_at(&path, line, Some(written), &message);
        };
        if !written.as_str().is_some_and(|variant| slot.variants.iter().any(|v| v == variant)) {
            let message = format!("expected one of {}", slot.variants.join(", "));
            return self.refuse_at(&path, line, Some(written), &message);
        }
        let key = setting_key(id);
        let Some(row) = self.schema.row_at(&key_path(&key)) else {
            return self.refuse_at(
                &path,
                line,
                Some(written),
                "this cmux has no setting for the slot",
            );
        };
        self.take(row, written);
    }
}
