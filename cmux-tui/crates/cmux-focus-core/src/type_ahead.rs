//! Keys typed into a page surface before its document can take them (spec
//! app-screens.md section 3, R59): one surface's printable text, in order,
//! bounded to [`MAX_CHARACTERS`] and [`MAX_AGE_NS`]. The app's key router
//! owns one queue and drops it on a chord or a focus move.
//!
//! Characters are extended grapheme clusters, as the app counts them.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

pub const MAX_CHARACTERS: usize = 256;
/// Two seconds, in the app's monotonic nanoseconds.
pub const MAX_AGE_NS: i64 = 2_000_000_000;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TypeAheadQueue {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<String>,
    #[serde(default)]
    pub text: String,
    /// When the queued text started, in monotonic nanoseconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_ns: Option<i64>,
}

impl TypeAheadQueue {
    /// Whether text waits for `surface`.
    pub fn pending(&self, surface: &str) -> bool {
        self.surface.as_deref() == Some(surface) && !self.text.is_empty()
    }

    /// Appends `characters` for `surface`; text for another surface, or text
    /// older than the maximum age, is dropped first. Characters past the
    /// maximum count are dropped.
    pub fn append(&mut self, characters: &str, surface: &str, now_ns: i64) {
        if self.surface.as_deref() != Some(surface) || self.is_expired(now_ns) {
            self.surface = Some(surface.to_owned());
            self.text.clear();
            self.started_ns = Some(now_ns);
        }
        let room = MAX_CHARACTERS.saturating_sub(self.text.graphemes(true).count());
        let taken: String = characters.graphemes(true).take(room).collect();
        self.text.push_str(&taken);
    }

    /// Delete while the page loads removes the last queued character.
    pub fn delete_backward(&mut self, surface: &str) {
        if self.surface.as_deref() != Some(surface) || self.text.is_empty() {
            return;
        }
        if let Some((index, _)) = self.text.grapheme_indices(true).next_back() {
            self.text.truncate(index);
        }
    }

    /// The queued text for `surface`, once; none when none waits or it is
    /// older than the maximum age (then it is dropped).
    pub fn take(&mut self, surface: &str, now_ns: i64) -> Option<String> {
        if self.surface.as_deref() != Some(surface) || self.text.is_empty() {
            return None;
        }
        let expired = self.is_expired(now_ns);
        let taken = std::mem::take(&mut self.text);
        self.drop_all();
        (!expired).then_some(taken)
    }

    pub fn drop_all(&mut self) {
        *self = TypeAheadQueue::default();
    }

    fn is_expired(&self, now_ns: i64) -> bool {
        self.started_ns.is_some_and(|started| now_ns.saturating_sub(started) > MAX_AGE_NS)
    }
}
