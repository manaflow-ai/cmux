//! One progress line of `cmux link seed push` (stderr, `{"progress":{...}}`; cmux-tui
//! `link/seed_cli.rs`), as numbers for the start card's clone row, and how often they are handed
//! on. The CLI and the page own the words; this only forwards fields.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// Least time between two progress values handed on (about 4 a second).
pub const EVERY_MS: f64 = 250.0;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Progress {
    /// `upload`, `clone`, `fetch`, `bundle`, `checkout`, `submodules`, `lfs`, or `copy` for the
    /// streamed copy (its lines carry files).
    pub phase: String,
    pub bytes_done: Option<i64>,
    pub bytes_total: Option<i64>,
    pub objects: Option<i64>,
    pub objects_total: Option<i64>,
    pub files_done: Option<i64>,
    pub files_total: Option<i64>,
    /// A seed that copied instead: why, and the cmux GitHub App's install link for `seed.needs_github`.
    pub fallback_code: Option<String>,
    #[serde(rename = "installURL")]
    pub install_url: Option<String>,
}

// A number of any form, truncated, as the app's NSNumber read it. f64 has no `TryFrom` into
// i64, and `as` saturates (NaN reads 0), so the cast never panics.
#[allow(
    clippy::cast_possible_truncation,
    reason = "an f64 count truncates and saturates on purpose, as the app's NSNumber read it"
)]
fn int(fields: &Map<String, Value>, key: &str) -> Option<i64> {
    fields
        .get(key)
        .and_then(|value| value.as_i64().or_else(|| value.as_f64().map(|value| value as i64)))
}

/// The line's progress; none for any other line.
pub fn parse(line: &str) -> Option<Progress> {
    if !line.starts_with('{') {
        return None;
    }
    let Value::Object(object) = serde_json::from_str::<Value>(line).ok()? else { return None };
    let fields = object.get("progress")?.as_object()?;
    let files_total = int(fields, "files_total");
    let phase = match fields.get("phase").and_then(Value::as_str) {
        Some(phase) => phase.to_owned(),
        None if files_total.is_some() => "copy".to_owned(),
        None => return None,
    };
    let text = |key: &str| fields.get(key).and_then(Value::as_str).map(str::to_owned);
    Some(Progress {
        phase,
        bytes_done: int(fields, "bytes_done"),
        bytes_total: int(fields, "bytes_total"),
        objects: int(fields, "objects"),
        objects_total: int(fields, "objects_total"),
        files_done: int(fields, "files_done"),
        files_total,
        fallback_code: text("fallback_code"),
        install_url: text("install_url"),
    })
}

/// What a reader remembers between lines.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Reader {
    pub last_ms: Option<f64>,
    pub phase: Option<String>,
    pub fallback_code: Option<String>,
    #[serde(rename = "installURL")]
    pub install_url: Option<String>,
}

impl Reader {
    /// The progress `line` hands on at `now_ms`, if any: at most one per [`EVERY_MS`], except a
    /// phase change, which always goes. A fallback's code and install link stay on the copy's
    /// lines after it.
    pub fn read(&mut self, line: &str, now_ms: f64) -> Option<Progress> {
        let mut progress = parse(line)?;
        if progress.fallback_code.is_some() {
            self.fallback_code.clone_from(&progress.fallback_code);
            self.install_url.clone_from(&progress.install_url);
        }
        progress.fallback_code.clone_from(&self.fallback_code);
        progress.install_url.clone_from(&self.install_url);
        let due = self.phase.as_deref() != Some(progress.phase.as_str())
            || self.last_ms.is_none_or(|last| now_ms - last >= EVERY_MS);
        if !due {
            return None;
        }
        self.last_ms = Some(now_ms);
        self.phase = Some(progress.phase.clone());
        Some(progress)
    }
}

#[cfg(test)]
mod tests;
