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
mod tests {
    use super::*;

    #[test]
    fn reads_the_seeds_copys_and_fallbacks_lines_and_nothing_else() {
        let upload =
            parse(r#"{"progress":{"phase":"upload","bytes_done":5,"bytes_total":9}}"#).unwrap();
        assert_eq!(
            upload,
            Progress {
                phase: "upload".into(),
                bytes_done: Some(5),
                bytes_total: Some(9),
                ..Progress::default()
            }
        );
        let copy = parse(
            r#"{"progress":{"files_done":1,"files_total":3,"bytes_done":4,"bytes_total":8}}"#,
        )
        .unwrap();
        assert_eq!(
            (copy.phase.as_str(), copy.files_done, copy.files_total),
            ("copy", Some(1), Some(3))
        );
        let fallback =
            parse(r#"{"progress":{"phase":"copy","fallback_code":"seed.needs_github","install_url":"https://github.com/apps/cmux"}}"#).unwrap();
        assert_eq!(fallback.fallback_code.as_deref(), Some("seed.needs_github"));
        assert_eq!(fallback.install_url.as_deref(), Some("https://github.com/apps/cmux"));
        assert_eq!(parse("warning: something"), None);
        assert_eq!(parse(r#"{"ok":true}"#), None);
        assert_eq!(parse(r#"{"progress":{"bytes_done":1}}"#), None, "no phase and no files");
    }

    #[test]
    fn throttles_but_a_phase_change_always_goes_and_a_fallback_stays_on_the_copy() {
        let mut reader = Reader::default();
        let mut seen = Vec::new();
        for (line, now) in [
            (r#"{"progress":{"phase":"upload","bytes_done":1,"bytes_total":9}}"#, 0.0),
            (r#"{"progress":{"phase":"upload","bytes_done":2,"bytes_total":9}}"#, 10.0),
            (r#"{"progress":{"phase":"copy","fallback_code":"not_git"}}"#, 20.0),
            (r#"{"progress":{"files_done":1,"files_total":2}}"#, 30.0),
            (r#"{"progress":{"files_done":2,"files_total":2}}"#, 300.0),
        ] {
            seen.extend(reader.read(line, now));
        }
        assert_eq!(
            seen.iter().map(|progress| progress.phase.as_str()).collect::<Vec<_>>(),
            ["upload", "copy", "copy"]
        );
        assert_eq!(seen.last().unwrap().fallback_code.as_deref(), Some("not_git"));
        assert_eq!(seen.last().unwrap().files_done, Some(2));
    }
}
