//! The two stores' rules: CmuxToastNeverShowStore (kinds hidden for good) and
//! CmuxToastStyleStore (the picked style over the configured one). The app owns UserDefaults;
//! these say what to write and when to tell followers.

use super::model::ToastStyle;
use serde::{Deserialize, Serialize};

/// CmuxToastNeverShowStore.defaultsKey.
pub const NEVER_SHOW_KEY: &str = "cmux.toasts.neverShow";
/// CmuxToastStyleStore.key.
pub const STYLE_KEY: &str = "cmux.toasts.style";

/// The kinds hidden for good, sorted.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NeverShowStore {
    #[serde(default)]
    pub kinds: Vec<String>,
}

impl NeverShowStore {
    pub fn load(stored: &[String]) -> Self {
        let mut kinds = stored.to_vec();
        kinds.sort();
        kinds.dedup();
        Self { kinds }
    }

    pub fn is_hidden(&self, kind: &str) -> bool {
        self.kinds.iter().any(|k| k == kind)
    }

    pub fn hidden_kinds(&self) -> Vec<String> {
        let mut kinds = self.kinds.clone();
        kinds.sort();
        kinds
    }

    /// Hides `kind`; true when it was new (the store persists only then).
    pub fn hide(&mut self, kind: &str) -> bool {
        if self.is_hidden(kind) {
            return false;
        }
        self.kinds.push(kind.into());
        self.kinds.sort();
        true
    }

    /// Shows every kind again; true when there were any.
    pub fn show_all(&mut self) -> bool {
        if self.kinds.is_empty() {
            return false;
        }
        self.kinds.clear();
        true
    }

    /// What to write under [`NEVER_SHOW_KEY`]: none removes the key.
    pub fn persisted(&self) -> Option<Vec<String>> {
        (!self.kinds.is_empty()).then(|| self.hidden_kinds())
    }
}

/// The style store's state: the person's pick over cmux.json's configured style.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StyleStore {
    #[serde(default)]
    pub picked: Option<ToastStyle>,
    #[serde(default = "standard")]
    pub configured: ToastStyle,
}

fn standard() -> ToastStyle {
    ToastStyle::Standard
}

impl Default for StyleStore {
    fn default() -> Self {
        Self { picked: None, configured: ToastStyle::Standard }
    }
}

/// What a pick writes: set the raw value, or remove the key.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "write", content = "value")]
pub enum StyleWrite {
    Set(&'static str),
    Remove,
}

impl StyleStore {
    /// The stored raw value; an unknown one is no pick.
    pub fn load(stored: Option<&str>, configured: ToastStyle) -> Self {
        Self { picked: stored.and_then(ToastStyle::from_raw), configured }
    }

    pub fn style(&self) -> ToastStyle {
        self.picked.unwrap_or(self.configured)
    }

    /// Picks `style`: none when it is the style already; else what to write (followers hear it).
    /// Picking the configured style clears the pick.
    pub fn pick(&mut self, style: ToastStyle) -> Option<StyleWrite> {
        if style == self.style() {
            return None;
        }
        self.picked = (style != self.configured).then_some(style);
        Some(match self.picked {
            Some(p) => StyleWrite::Set(p.raw_value()),
            None => StyleWrite::Remove,
        })
    }

    /// Sets cmux.json's style; true when the drawn style changed (followers hear it).
    pub fn configure(&mut self, style: ToastStyle) -> bool {
        let before = self.style();
        self.configured = style;
        self.style() != before
    }
}
