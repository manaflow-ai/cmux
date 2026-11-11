//! Validate before apply: what is wrong with the live tree, by file and
//! line, in the words of the validators cmux itself runs (the settings
//! owner's schema, the app manifest validator).
//!
//! A problem never stops a preview: each surface already keeps its last good
//! version on screen when a save does not load. It stops an apply, so a
//! generation is always a setup that loads.

use std::collections::BTreeMap;

use cmux_config::{FileRead, Schema, State, jsonc};
use serde::Serialize;
use serde_json::Value;

use crate::tree::Part;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    /// The logical path of the file.
    pub path: String,
    pub part: Part,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub line: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub column: Option<u32>,
    pub message: String,
}

impl Problem {
    fn at(
        path: &str,
        line: Option<u32>,
        column: Option<u32>,
        message: impl Into<String>,
    ) -> Problem {
        Problem {
            path: path.to_owned(),
            part: Part::of(path),
            line,
            column,
            message: message.into(),
        }
    }

    /// `themes/night.json:14:9: message`, the shape a compiler prints.
    pub fn line(&self) -> String {
        match (self.line, self.column) {
            (Some(line), Some(column)) => {
                format!("{}:{line}:{column}: {}", self.path, self.message)
            }
            (Some(line), None) => format!("{}:{line}: {}", self.path, self.message),
            _ => format!("{}: {}", self.path, self.message),
        }
    }
}

/// Every problem in `files` (logical path to bytes). Only the paths given
/// are read, so a caller checks just what changed, or the whole tree.
pub fn problems(files: &BTreeMap<String, Vec<u8>>) -> Vec<Problem> {
    let mut found = Vec::new();
    for (path, bytes) in files {
        let Ok(text) = std::str::from_utf8(bytes) else {
            if is_text_path(path) {
                found.push(Problem::at(path, None, None, "is not UTF-8 text"));
            }
            continue;
        };
        if let Some((line, column, name)) = hidden_direction_mark(text) {
            found.push(Problem::at(
                path,
                Some(line),
                Some(column),
                format!("has an invisible text-direction character ({name}); what you read is not what runs"),
            ));
        }
        match Part::of(path) {
            Part::Settings => settings(path, text, &mut found),
            Part::Keybindings => keybindings(path, text, &mut found),
            Part::Themes | Part::Automations => {
                json_object(path, text, &mut found);
            }
            Part::Views => view(path, text, files, &mut found),
            Part::Styles => {}
        }
    }
    // Whatever a validator quoted from a file goes through the same masking
    // as a diff: a problem is read by agents too.
    for problem in &mut found {
        problem.message = crate::redact::text(&problem.message);
    }
    found
}

fn is_text_path(path: &str) -> bool {
    [".json", ".js", ".ts", ".css", ".md", ".txt"].iter().any(|ending| path.ends_with(ending))
}

fn settings(path: &str, text: &str, found: &mut Vec<Problem>) {
    if text.trim().is_empty() {
        return;
    }
    if json_object(path, text, found).is_none() {
        return;
    }
    // The owner's own reading of the file: no managed layers and no published
    // value domains, as `cmux settings validate` reads it.
    let state = State::new(
        Schema::embedded(),
        FileRead::Text(text.to_owned()),
        Default::default(),
        Default::default(),
        Default::default(),
        0,
    );
    for diagnostic in state.snapshot().diagnostics {
        let (line, column) = line_of_key(text, &diagnostic.path).unzip();
        // The owner's message quotes the refused value, and a value may be
        // a credential typed under the wrong key. The key and its line say
        // where to look; the value stays in the file.
        let message = match diagnostic.kind {
            cmux_config::diagnostics::DiagnosticKind::InvalidValue => {
                format!("{} has a value this setting does not accept", diagnostic.path)
            }
            _ => diagnostic.message,
        };
        found.push(Problem::at(path, line, column, message));
    }
}

/// The shortcuts file by its own reader (`cmux_config::keybindings`): a
/// JSONC array of bindings, and an empty or comment-only file is fine. Only
/// a file that reader cannot load at all stops an apply; one bad entry is
/// skipped by the app and shown on its Settings row, as before.
fn keybindings(path: &str, text: &str, found: &mut Vec<Problem>) {
    let unreadable = cmux_config::keybindings::parse(text)
        .diagnostics
        .into_iter()
        .find(|entry| entry.problem == cmux_config::keybindings::Problem::UnreadableFile);
    let Some(unreadable) = unreadable else { return };
    // The parse error with its line when the text is not JSON at all.
    match json_value(path, text, found) {
        Some(value) if value.is_array() => {
            found.push(Problem::at(path, Some(1), None, unreadable.message));
        }
        Some(_) => found.push(Problem::at(
            path,
            Some(1),
            None,
            "must be a JSON array of bindings, like [{ \"key\": \"cmd+k\", \"command\": \"...\" }]",
        )),
        None => {}
    }
}

/// Parses a JSON object with comments; pushes what is wrong with its position.
fn json_object(path: &str, text: &str, found: &mut Vec<Problem>) -> Option<Value> {
    match json_value(path, text, found) {
        Some(value) if value.is_object() => Some(value),
        Some(_) => {
            found.push(Problem::at(path, Some(1), None, "must be a JSON object"));
            None
        }
        None => None,
    }
}

/// Parses JSON with comments; pushes the parse error with its position.
fn json_value(path: &str, text: &str, found: &mut Vec<Problem>) -> Option<Value> {
    match jsonc::parse(text) {
        Ok(value) => Some(value),
        Err(error) => {
            let (line, column, message) = match &error {
                jsonc::JsoncError::Malformed { offset } => {
                    let (line, column) = line_column(text, *offset);
                    (Some(line), Some(column), "malformed JSON".to_owned())
                }
                jsonc::JsoncError::Json(message) => {
                    let (line, column) = serde_position(message).unzip();
                    (line, column, strip_serde_position(message))
                }
                other => (None, None, other.to_string()),
            };
            found.push(Problem::at(path, line, column, message));
            None
        }
    }
}

/// The views app: its manifest by the validator the daemon runs, and the
/// script the manifest names must be there.
fn view(path: &str, text: &str, files: &BTreeMap<String, Vec<u8>>, found: &mut Vec<Problem>) {
    if path != "customize/cmux-app.json" && path != "customize/cmux-app.v2.json" {
        return;
    }
    let Some(manifest) = json_object(path, text, found) else { return };
    for issue in cmux_app_manifest::validate_manifest(&manifest) {
        if issue.severity != cmux_app_manifest::Severity::Error {
            continue;
        }
        let key =
            issue.path.rsplit('/').next().unwrap_or_default().replace("~1", "/").replace("~0", "~");
        let (line, column) = line_of_key(text, &key).unzip();
        let at = if issue.path.is_empty() { String::new() } else { format!("{}: ", issue.path) };
        found.push(Problem::at(path, line, column, format!("{at}{}", issue.message)));
    }
    if let Some(id) = manifest.get("id").and_then(Value::as_str)
        && id != "local/customize"
    {
        let (line, column) = line_of_key(text, "id").unzip();
        found.push(Problem::at(
            path,
            line,
            column,
            format!("id is {id:?}; the views app in this folder is \"local/customize\""),
        ));
    }
    if let Some(main) = manifest.pointer("/runtime/main").and_then(Value::as_str)
        && !files.contains_key(&format!("customize/{main}"))
    {
        let (line, column) = line_of_key(text, "main").unzip();
        found.push(Problem::at(
            path,
            line,
            column,
            format!("runtime.main names {main:?}, which is not in the folder"),
        ));
    }
}

/// U+202A..U+202E and U+2066..U+2069 reorder what a reader sees without
/// changing what a parser reads (the "Trojan Source" class). First hit, as
/// 1-based line and column.
fn hidden_direction_mark(text: &str) -> Option<(u32, u32, String)> {
    for (index, line) in text.lines().enumerate() {
        for (column, character) in line.chars().enumerate() {
            if matches!(character, '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}') {
                return Some((
                    index as u32 + 1,
                    column as u32 + 1,
                    format!("U+{:04X}", character as u32),
                ));
            }
        }
    }
    None
}

fn line_column(text: &str, offset: usize) -> (u32, u32) {
    let before = text.as_bytes().get(..offset.min(text.len())).unwrap_or_default();
    let line = before.iter().filter(|byte| **byte == b'\n').count() as u32 + 1;
    let column = before.iter().rev().take_while(|byte| **byte != b'\n').count() as u32 + 1;
    (line, column)
}

/// `"… at line 3 column 7"`, the tail serde_json puts on a message.
fn serde_position(message: &str) -> Option<(u32, u32)> {
    let (_, tail) = message.rsplit_once(" at line ")?;
    let (line, column) = tail.split_once(" column ")?;
    Some((line.trim().parse().ok()?, column.trim().parse().ok()?))
}

fn strip_serde_position(message: &str) -> String {
    message.rsplit_once(" at line ").map_or(message, |(head, _)| head).to_owned()
}

/// Where a dotted key's last name is written as an object key: best effort,
/// so an error names a line an editor can jump to.
fn line_of_key(text: &str, dotted: &str) -> Option<(u32, u32)> {
    let name = dotted.rsplit('.').next().filter(|name| !name.is_empty())?;
    let needle = format!("\"{name}\"");
    text.match_indices(&needle)
        .find(|(at, _)| {
            text.get(at + needle.len()..).is_some_and(|after| after.trim_start().starts_with(':'))
        })
        .map(|(at, _)| line_column(text, at))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tree::SETTINGS;

    fn check(path: &str, text: &str) -> Vec<String> {
        let files = BTreeMap::from([(path.to_owned(), text.as_bytes().to_vec())]);
        problems(&files).iter().map(Problem::line).collect()
    }

    #[test]
    fn a_json_mistake_names_its_line_and_column() {
        let lines = check("themes/night.json", "{\n  \"name\": \"night\",\n  \"look\": }\n}\n");
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert!(lines[0].starts_with("themes/night.json:3:"), "{lines:?}");
    }

    #[test]
    fn a_shortcuts_file_is_an_array_and_only_an_unreadable_one_is_a_problem() {
        let valid = "// mine\n[\n  { \"key\": \"cmd+k\", \"command\": \"palette.open\" },\n]\n";
        assert_eq!(check("keybindings.json", valid), Vec::<String>::new());
        assert_eq!(check("keybindings.json", ""), Vec::<String>::new());
        assert_eq!(check("keybindings.json", "// nothing yet\n"), Vec::<String>::new());
        // One entry the app skips does not stop an apply of something else.
        assert_eq!(check("keybindings.json", "[ { \"key\": \"cmd+k\" } ]"), Vec::<String>::new());
        let object = check("keybindings.json", "{ \"cmd+k\": \"palette.open\" }");
        assert_eq!(object.len(), 1, "{object:?}");
        assert!(object[0].contains("must be a JSON array of bindings"), "{object:?}");
        let broken = check("keybindings.json", "[\n  { \"key\": }\n]\n");
        assert_eq!(broken.len(), 1, "{broken:?}");
        assert!(broken[0].starts_with("keybindings.json:2:"), "{broken:?}");
    }

    #[test]
    fn a_settings_value_the_schema_refuses_names_its_key_line() {
        let lines =
            check(SETTINGS, "{\n  // mine\n  \"appearance\": {\n    \"density\": 42\n  }\n}\n");
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert!(lines[0].starts_with("settings.json:4:5: "), "{lines:?}");
    }

    #[test]
    fn a_problem_never_quotes_the_value_it_refuses() {
        let lines = check(
            SETTINGS,
            "{\n  \"appearance\": { \"density\": { \"apiKey\": \"private-value\" } },\n  \"updates\": { \"channel\": \"my-private-ring\" }\n}\n",
        );
        assert_eq!(lines.len(), 2, "{lines:?}");
        let said = lines.join("\n");
        assert!(!said.contains("private"), "{said}");
        assert!(
            said.contains("appearance.density has a value this setting does not accept"),
            "{said}"
        );
        assert!(said.contains("settings.json:3:"), "{said}");
    }

    #[test]
    fn valid_files_have_no_problems() {
        assert_eq!(check(SETTINGS, ""), Vec::<String>::new());
        assert_eq!(
            check(SETTINGS, "{ /* c */ \"appearance\": { \"density\": \"compact\" }, }"),
            Vec::<String>::new()
        );
        assert_eq!(
            check("agent-pane/theme.css", ":root { --agent-gap: 4px }"),
            Vec::<String>::new()
        );
    }

    #[test]
    fn a_hidden_direction_mark_is_refused_with_its_position() {
        let lines = check("customize/main.js", "let a = 1;\nlet b = \"\u{202E}x\";\n");
        assert_eq!(lines.len(), 1);
        assert!(lines[0].starts_with("customize/main.js:2:10: "), "{lines:?}");
        assert!(lines[0].contains("U+202E"));
    }

    #[test]
    fn the_views_manifest_must_name_a_script_that_is_there() {
        let manifest = r#"{
  "manifestVersion": 2,
  "id": "local/customize",
  "name": "My views",
  "version": "1.0.0",
  "engines": { "cmux": "^2.0" },
  "runtime": { "main": "main.js" },
  "implements": { "cmux.section/1": { "export": "renderSection", "title": "Mine", "symbol": "sparkles" } },
  "description": "My own views"
}"#;
        let lines = check("customize/cmux-app.json", manifest);
        assert_eq!(lines.len(), 1, "{lines:?}");
        assert!(lines[0].starts_with("customize/cmux-app.json:7:16: runtime.main"), "{lines:?}");
        let files = BTreeMap::from([
            ("customize/cmux-app.json".to_owned(), manifest.as_bytes().to_vec()),
            ("customize/main.js".to_owned(), b"export function renderSection() {}".to_vec()),
        ]);
        assert_eq!(problems(&files), Vec::new());
    }
}
