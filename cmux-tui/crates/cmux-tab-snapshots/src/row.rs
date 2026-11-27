//! The manifest row and the partial row ([`RowPatch`]) that a delta carries.

use crate::hash::{BlobHash, Mime};
use serde::de::Deserializer;
use serde::{Deserialize, Serialize, Serializer};

/// What a tab shows. Serialized lowercase. A kind this build does not know
/// decodes to [`Kind::Other`], so an old phone keeps working with a new Mac.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Kind {
    Browser,
    Terminal,
    Agent,
    Other(String),
}

impl Default for Kind {
    fn default() -> Self {
        Self::Other(String::new())
    }
}

impl Kind {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Browser => "browser",
            Self::Terminal => "terminal",
            Self::Agent => "agent",
            Self::Other(text) => text,
        }
    }

    pub fn parse(text: &str) -> Self {
        match text {
            "browser" => Self::Browser,
            "terminal" => Self::Terminal,
            "agent" => Self::Agent,
            other => Self::Other(other.to_owned()),
        }
    }
}

impl Serialize for Kind {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for Kind {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Ok(Self::parse(&text))
    }
}

/// One card in the phone's tab overview. Every hash is optional and omitted
/// from JSON when absent. Missing fields decode to their defaults and unknown
/// fields are ignored.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Row {
    pub tab_id: String,
    /// The tab's durable id on the Mac (the daemon's `tab_resource_id`):
    /// unlike `tabId`, a surface id that only means something within one run
    /// of the daemon, it stays the tab's across daemon restarts and is never
    /// given to another tab. Empty when unknown.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub tab_key: String,
    pub title: String,
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub favicon_hash: Option<BlobHash>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thumb_hash: Option<BlobHash>,
    pub thumb_w: u32,
    pub thumb_h: u32,
    pub thumb_mime: Mime,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screen_hash: Option<BlobHash>,
    pub screen_cols: u32,
    pub screen_rows: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub frame_hash: Option<BlobHash>,
    pub captured_at_ms: i64,
}

impl Row {
    /// Every hash the row references, favicon first.
    pub fn hashes(&self) -> impl Iterator<Item = BlobHash> + '_ {
        [self.favicon_hash, self.thumb_hash, self.screen_hash, self.frame_hash]
            .into_iter()
            .flatten()
    }

    /// True when the rows show the same thing. `capturedAtMs` is not content:
    /// a recapture with the same bytes is not a change.
    pub fn same_content(&self, other: &Self) -> bool {
        self.tab_key == other.tab_key
            && self.title == other.title
            && self.kind == other.kind
            && self.favicon_hash == other.favicon_hash
            && self.thumb_hash == other.thumb_hash
            && self.thumb_w == other.thumb_w
            && self.thumb_h == other.thumb_h
            && self.thumb_mime == other.thumb_mime
            && self.screen_hash == other.screen_hash
            && self.screen_cols == other.screen_cols
            && self.screen_rows == other.screen_rows
            && self.frame_hash == other.frame_hash
    }
}

/// Reads a present field as `Some(value)`, so a JSON `null` becomes
/// `Some(None)` (cleared) while an absent field stays `None` (unchanged).
fn present<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

/// A row in a delta: `tabId` plus only the fields that changed. For a hash,
/// an absent field means unchanged and `null` means the row no longer has
/// that blob. A tab the phone has not seen arrives with every field.
#[derive(Clone, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RowPatch {
    pub tab_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tab_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<Kind>,
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "present")]
    pub favicon_hash: Option<Option<BlobHash>>,
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "present")]
    pub thumb_hash: Option<Option<BlobHash>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thumb_w: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thumb_h: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thumb_mime: Option<Mime>,
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "present")]
    pub screen_hash: Option<Option<BlobHash>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screen_cols: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub screen_rows: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none", deserialize_with = "present")]
    pub frame_hash: Option<Option<BlobHash>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub captured_at_ms: Option<i64>,
}

fn changed<T: PartialEq + Clone>(old: &T, new: &T) -> Option<T> {
    (old != new).then(|| new.clone())
}

fn take<T>(slot: &mut T, value: Option<T>) {
    if let Some(value) = value {
        *slot = value;
    }
}

fn later<T>(earlier: &mut Option<T>, value: Option<T>) {
    if value.is_some() {
        *earlier = value;
    }
}

impl RowPatch {
    /// Every field of `row`, for a tab the phone has not seen.
    pub fn full(row: &Row) -> Self {
        Self {
            tab_id: row.tab_id.clone(),
            tab_key: Some(row.tab_key.clone()),
            title: Some(row.title.clone()),
            kind: Some(row.kind.clone()),
            favicon_hash: Some(row.favicon_hash),
            thumb_hash: Some(row.thumb_hash),
            thumb_w: Some(row.thumb_w),
            thumb_h: Some(row.thumb_h),
            thumb_mime: Some(row.thumb_mime),
            screen_hash: Some(row.screen_hash),
            screen_cols: Some(row.screen_cols),
            screen_rows: Some(row.screen_rows),
            frame_hash: Some(row.frame_hash),
            captured_at_ms: Some(row.captured_at_ms),
        }
    }

    /// The fields that differ from `old` to `new`, or `None` when the content
    /// is the same. `capturedAtMs` rides along only with a real change.
    pub fn diff(old: &Row, new: &Row) -> Option<Self> {
        if old.same_content(new) {
            return None;
        }
        Some(Self {
            tab_id: new.tab_id.clone(),
            tab_key: changed(&old.tab_key, &new.tab_key),
            title: changed(&old.title, &new.title),
            kind: changed(&old.kind, &new.kind),
            favicon_hash: changed(&old.favicon_hash, &new.favicon_hash),
            thumb_hash: changed(&old.thumb_hash, &new.thumb_hash),
            thumb_w: changed(&old.thumb_w, &new.thumb_w),
            thumb_h: changed(&old.thumb_h, &new.thumb_h),
            thumb_mime: changed(&old.thumb_mime, &new.thumb_mime),
            screen_hash: changed(&old.screen_hash, &new.screen_hash),
            screen_cols: changed(&old.screen_cols, &new.screen_cols),
            screen_rows: changed(&old.screen_rows, &new.screen_rows),
            frame_hash: changed(&old.frame_hash, &new.frame_hash),
            captured_at_ms: changed(&old.captured_at_ms, &new.captured_at_ms),
        })
    }

    /// Folds a later patch for the same tab into this one: a field the later
    /// patch carries wins.
    pub fn merge(&mut self, next: Self) {
        later(&mut self.tab_key, next.tab_key);
        later(&mut self.title, next.title);
        later(&mut self.kind, next.kind);
        later(&mut self.favicon_hash, next.favicon_hash);
        later(&mut self.thumb_hash, next.thumb_hash);
        later(&mut self.thumb_w, next.thumb_w);
        later(&mut self.thumb_h, next.thumb_h);
        later(&mut self.thumb_mime, next.thumb_mime);
        later(&mut self.screen_hash, next.screen_hash);
        later(&mut self.screen_cols, next.screen_cols);
        later(&mut self.screen_rows, next.screen_rows);
        later(&mut self.frame_hash, next.frame_hash);
        later(&mut self.captured_at_ms, next.captured_at_ms);
    }

    /// Writes the carried fields into `row`.
    pub fn apply(&self, row: &mut Row) {
        take(&mut row.tab_key, self.tab_key.clone());
        take(&mut row.title, self.title.clone());
        take(&mut row.kind, self.kind.clone());
        take(&mut row.favicon_hash, self.favicon_hash);
        take(&mut row.thumb_hash, self.thumb_hash);
        take(&mut row.thumb_w, self.thumb_w);
        take(&mut row.thumb_h, self.thumb_h);
        take(&mut row.thumb_mime, self.thumb_mime);
        take(&mut row.screen_hash, self.screen_hash);
        take(&mut row.screen_cols, self.screen_cols);
        take(&mut row.screen_rows, self.screen_rows);
        take(&mut row.frame_hash, self.frame_hash);
        take(&mut row.captured_at_ms, self.captured_at_ms);
    }
}

/// Puts `rows` in `order`: the listed tabs first, in the listed order, then
/// every unlisted tab in its old relative order. Unknown and repeated ids
/// in `order` are ignored. Returns true when the order changed.
pub fn reorder<S: AsRef<str>>(rows: &mut Vec<Row>, order: &[S]) -> bool {
    let mut pending: Vec<Option<Row>> = std::mem::take(rows).into_iter().map(Some).collect();
    let before: Vec<String> = pending.iter().flatten().map(|r| r.tab_id.clone()).collect();
    let mut out = Vec::with_capacity(pending.len());
    for id in order {
        let id = id.as_ref();
        let slot = pending.iter_mut().find(|r| r.as_ref().is_some_and(|r| r.tab_id == id));
        if let Some(row) = slot.and_then(Option::take) {
            out.push(row);
        }
    }
    out.extend(pending.into_iter().flatten());
    let changed = out.iter().map(|r| r.tab_id.as_str()).ne(before.iter().map(String::as_str));
    *rows = out;
    changed
}
