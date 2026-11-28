//! The journal's records: an occurrence ([`Event`]), a folded problem ([`Entry`]), the stored line
//! that adds the redaction stamp, and the level ladder.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// How bad a problem is; ordered warning < error < fault < crash.
#[derive(
    Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize, Default,
)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    /// Something degraded but kept working.
    #[default]
    Warning,
    /// An operation failed.
    Error,
    /// A component failed (a panic, an OS fault).
    Fault,
    /// A process crashed.
    Crash,
}

impl Level {
    /// The lowercase name the journal stores.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Warning => "warning",
            Self::Error => "error",
            Self::Fault => "fault",
            Self::Crash => "crash",
        }
    }
}

/// One occurrence of a problem, before it is folded. `date` is seconds since 1970.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Event {
    /// Who reported it: `app`, `acpmux`, `page:<name>`, `system:<subsystem>`, `crash`.
    pub source: String,
    /// How bad it is.
    pub level: Level,
    /// The message as it was reported (redacted before it is kept).
    pub message: String,
    /// The innermost frame or `file:line`, when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_frame: Option<String>,
    /// Extra fields (bounded and redacted before they are kept).
    #[serde(default)]
    pub context: BTreeMap<String, String>,
    /// When it happened, seconds since 1970.
    pub date: f64,
}

impl Event {
    /// An event with no frame or context.
    pub fn new(source: &str, level: Level, message: &str, date: f64) -> Self {
        Self {
            source: source.to_owned(),
            level,
            message: message.to_owned(),
            top_frame: None,
            context: BTreeMap::new(),
            date,
        }
    }
}

/// A problem folded over its occurrences. Its JSON is the journal line's (keys sorted, `ctx` left
/// out when empty), without the redaction stamp.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// Occurrences folded into it.
    pub count: u64,
    /// Extra fields of the newest occurrence.
    #[serde(rename = "ctx", default, skip_serializing_if = "BTreeMap::is_empty")]
    pub context: BTreeMap<String, String>,
    /// The first occurrence, ms since 1970.
    pub first_ms: i64,
    /// The identity: [`crate::fingerprint`] of source, template and frame.
    #[serde(rename = "fp")]
    pub fingerprint: String,
    /// The innermost frame, when known.
    #[serde(rename = "frame", default, skip_serializing_if = "Option::is_none")]
    pub top_frame: Option<String>,
    /// The newest occurrence, ms since 1970.
    pub last_ms: i64,
    /// The worst level seen.
    pub level: Level,
    /// The newest occurrence's redacted message.
    pub sample: String,
    /// Who reported it.
    pub source: String,
    /// The message with its values replaced by placeholders.
    pub template: String,
}

/// A journal line: the entry's fields plus `redacted_by`, the rules digest that redacted it.
#[derive(Serialize)]
struct StoredLine<'a> {
    count: u64,
    #[serde(rename = "ctx", skip_serializing_if = "BTreeMap::is_empty")]
    context: &'a BTreeMap<String, String>,
    first_ms: i64,
    fp: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    frame: Option<&'a str>,
    last_ms: i64,
    level: Level,
    redacted_by: &'a str,
    sample: &'a str,
    source: &'a str,
    template: &'a str,
}

#[derive(Deserialize)]
struct LoadedLine {
    #[serde(flatten)]
    entry: Entry,
    #[serde(default)]
    redacted_by: Option<String>,
}

/// One journal line (keys sorted, no trailing newline) for `entry` stamped with `digest`.
pub fn stored_line(entry: &Entry, digest: &str) -> String {
    let line = StoredLine {
        count: entry.count,
        context: &entry.context,
        first_ms: entry.first_ms,
        fp: &entry.fingerprint,
        frame: entry.top_frame.as_deref(),
        last_ms: entry.last_ms,
        level: entry.level,
        redacted_by: digest,
        sample: &entry.sample,
        source: &entry.source,
        template: &entry.template,
    };
    serde_json::to_string(&line).unwrap_or_default()
}

/// The lines of `entries`, each ending in "\n".
pub fn stored_lines(entries: &[&Entry], digest: &str) -> String {
    let mut text = String::new();
    for entry in entries {
        text.push_str(&stored_line(entry, digest));
        text.push('\n');
    }
    text
}

/// Decodes a journal line: the entry and its redaction stamp. None when it is not one.
pub fn parse_stored_line(line: &str) -> Option<(Entry, Option<String>)> {
    let loaded: LoadedLine = serde_json::from_str(line).ok()?;
    Some((loaded.entry, loaded.redacted_by))
}
