//! The code editor's defaults from another editor (`editor.importFrom`), the
//! port of Swift `EditorSettingsImport`, `EditorSettingsSources`,
//! `ImportableEditor`, `EditorImportChoice`, `copyEditorSettings` and
//! `EditorPreferenceToggle`.
//!
//! VS Code and the editors built on it (Cursor, Windsurf, VSCodium) give a
//! `settings.json` and a `keybindings.json`; Zed a `settings.json` and a
//! `keymap.json`. [`vscode`] and [`zed`] map them to the `editor` section
//! (cmux-next.json keys, Monaco's and VS Code's names). Only keys the code
//! editor reads come over, in the shape its Settings rows accept, so a value
//! copied into cmux-next.json loads without a diagnostic. Language blocks
//! (`"[python]"`, Zed's `languages`) become `languages.<id>`; bindings for
//! editor commands become `keybindings` (VS Code's `{key, command, when}`).
//!
//! The app reads the files ([`files`] says which) and hands their text to
//! [`load`]; nothing here touches the disk.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use crate::domains::Domains;
use crate::schema::{self, Kind, Schema};
use crate::value::{canonical, char_count, number_value, value_at, with_value};

/// An editor whose settings the code editor can take its defaults from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Editor {
    /// Visual Studio Code: `~/Library/Application Support/Code/User`.
    Vscode,
    /// Cursor (VS Code's format).
    Cursor,
    /// Windsurf (VS Code's format).
    Windsurf,
    /// VSCodium (VS Code's format).
    Vscodium,
    /// Zed: `~/.config/zed`.
    Zed,
}

impl Editor {
    /// Every editor, in the order `auto` tries them.
    pub const ALL: [Editor; 5] =
        [Editor::Vscode, Editor::Cursor, Editor::Windsurf, Editor::Vscodium, Editor::Zed];

    /// The `editor.importFrom` choice naming it.
    pub fn id(self) -> &'static str {
        match self {
            Editor::Vscode => "vscode",
            Editor::Cursor => "cursor",
            Editor::Windsurf => "windsurf",
            Editor::Vscodium => "vscodium",
            Editor::Zed => "zed",
        }
    }

    /// The editor a choice value names.
    pub fn from_id(id: &str) -> Option<Editor> {
        Editor::ALL.into_iter().find(|editor| editor.id() == id)
    }

    /// The name a person knows it by (a product name: not translated).
    pub fn name(self) -> &'static str {
        match self {
            Editor::Vscode => "VS Code",
            Editor::Cursor => "Cursor",
            Editor::Windsurf => "Windsurf",
            Editor::Vscodium => "VSCodium",
            Editor::Zed => "Zed",
        }
    }
}

/// `editor.importFrom`: which editor's settings give the code editor its defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Choice {
    /// The first editor in [`Editor::ALL`] order with a settings file (the default).
    Auto,
    /// No other editor.
    None,
    /// One editor.
    Editor(Editor),
}

impl Choice {
    /// The choice `editor.importFrom` holds; an absent or unknown value is `Auto`.
    pub fn from_setting(setting: Option<&str>) -> Choice {
        match setting {
            Some("none") => Choice::None,
            Some(name) => Editor::from_id(name).map_or(Choice::Auto, Choice::Editor),
            None => Choice::Auto,
        }
    }

    /// The setting value: `auto`, `none` or an editor id.
    pub fn id(self) -> &'static str {
        match self {
            Choice::Auto => "auto",
            Choice::None => "none",
            Choice::Editor(editor) => editor.id(),
        }
    }

    /// The editors this choice reads, in order.
    pub fn editors(self) -> Vec<Editor> {
        match self {
            Choice::Auto => Editor::ALL.to_vec(),
            Choice::None => Vec::new(),
            Choice::Editor(editor) => vec![editor],
        }
    }
}

/// The settings file and the key bindings file of `editor` under `home`.
pub fn files(home: &str, editor: Editor) -> (String, String) {
    let home = home.trim_end_matches('/');
    let code = |folder: &str| {
        let user = format!("{home}/Library/Application Support/{folder}/User");
        (format!("{user}/settings.json"), format!("{user}/keybindings.json"))
    };
    match editor {
        Editor::Vscode => code("Code"),
        Editor::Cursor => code("Cursor"),
        Editor::Windsurf => code("Windsurf"),
        Editor::Vscodium => code("VSCodium"),
        Editor::Zed => {
            (format!("{home}/.config/zed/settings.json"), format!("{home}/.config/zed/keymap.json"))
        }
    }
}

/// Every file a choice may read (what a watcher watches).
pub fn watched_files(home: &str, choice: Choice) -> Vec<String> {
    choice
        .editors()
        .into_iter()
        .flat_map(|editor| {
            let (settings, keys) = files(home, editor);
            [settings, keys]
        })
        .collect()
}

/// What [`load`] found: the editor, the files it read and the mapped section.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub editor: Editor,
    /// Its settings file, then its key bindings file when that parsed.
    pub files: Vec<String>,
    pub section: Value,
}

/// The mapped section of the chosen editor, or of the first editor in
/// [`Editor::ALL`] order whose settings file parses to an object (`auto`).
/// `read` gives a file's text, `None` when it is absent or unreadable.
pub fn load(home: &str, choice: Choice, read: impl Fn(&str) -> Option<String>) -> Option<Found> {
    for editor in choice.editors() {
        let (settings_file, keys_file) = files(home, editor);
        let Some(settings) = read(&settings_file).and_then(|text| crate::jsonc::parse(&text).ok())
        else {
            continue;
        };
        if !settings.is_object() {
            continue;
        }
        let keys = read(&keys_file).and_then(|text| crate::jsonc::parse(&text).ok());
        let section = map(editor, &settings, keys.as_ref());
        let mut read_files = vec![settings_file];
        if keys.is_some() {
            read_files.push(keys_file);
        }
        return Some(Found { editor, files: read_files, section });
    }
    None
}

/// The `editor` section for `editor`'s parsed settings and key bindings.
pub fn map(editor: Editor, settings: &Value, keys: Option<&Value>) -> Value {
    let settings = canonical(settings.clone());
    let keys = keys.cloned().map(canonical);
    match editor {
        Editor::Zed => zed(&settings, keys.as_ref()),
        _ => vscode(&settings, keys.as_ref()),
    }
}

// MARK: VS Code

/// The `editor` keys VS Code names `editor.<key>` with the same values.
const VSCODE_SAME_KEYS: [&str; 31] = [
    "fontFamily",
    "fontSize",
    "lineHeight",
    "letterSpacing",
    "tabSize",
    "insertSpaces",
    "detectIndentation",
    "wordWrap",
    "wordWrapColumn",
    "minimap.enabled",
    "lineNumbers",
    "renderWhitespace",
    "renderControlCharacters",
    "renderLineHighlight",
    "bracketPairColorization.enabled",
    "guides.indentation",
    "matchBrackets",
    "stickyScroll.enabled",
    "folding",
    "scrollBeyondLastLine",
    "smoothScrolling",
    "mouseWheelZoom",
    "cursorStyle",
    "cursorBlinking",
    "cursorSurroundingLines",
    "multiCursorModifier",
    "linkedEditing",
    "acceptSuggestionOnEnter",
    "emptySelectionClipboard",
    "find.seedSearchStringFromSelection",
    "formatOnSave",
];

/// The keys a language block may set (`editor.languages.<id>`).
const LANGUAGE_KEYS: [&str; 6] =
    ["tabSize", "insertSpaces", "detectIndentation", "wordWrap", "rulers", "formatOnSave"];

/// Monaco's commands besides `editor.*`: cursor undo and find.
const MONACO_COMMANDS: [&str; 6] =
    ["cursorUndo", "cursorRedo", "actions.find", "actions.findWithSelection", "undo", "redo"];

fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.as_object()?.get(key)
}

fn split_dots(key: &str) -> Vec<String> {
    key.split('.').filter(|part| !part.is_empty()).map(str::to_owned).collect()
}

/// The `editor` section for a VS Code `settings.json` (parsed) and its
/// `keybindings.json` (`None` when the file is absent).
pub fn vscode(settings: &Value, keybindings: Option<&Value>) -> Value {
    let mut out = Map::new();
    let empty = Map::new();
    let root = settings.as_object().unwrap_or(&empty);
    let flat = |key: &str| root.get(key).or_else(|| value_at(settings, &split_dots(key)));
    for key in VSCODE_SAME_KEYS {
        if let Some(value) =
            flat(&format!("editor.{key}")).and_then(|value| vscode_value(key, value))
        {
            set(&mut out, key, value);
        }
    }
    if let Some(weight) = flat("editor.fontWeight").and_then(font_weight) {
        out.insert("fontWeight".into(), weight);
    }
    if let Some(ligatures) = flat("editor.fontLigatures") {
        // VS Code also takes a feature string ("'ss01', 'calt'"): ligatures on.
        let on = ligatures
            .as_bool()
            .unwrap_or_else(|| !ligatures.as_str().unwrap_or_default().is_empty());
        out.insert("fontLigatures".into(), Value::Bool(on));
    }
    if let Some(rulers) = flat("editor.rulers").and_then(rulers) {
        out.insert("rulers".into(), rulers);
    }
    for key in ["autoClosingBrackets", "autoClosingQuotes"] {
        if let Some(value) = flat(&format!("editor.{key}")) {
            out.insert(
                key.into(),
                Value::Bool(value.as_bool().unwrap_or(value.as_str() != Some("never"))),
            );
        }
    }
    // VS Code's `true`, `"active"` or `false`.
    if let Some(value) = flat("editor.guides.bracketPairs") {
        set(
            &mut out,
            "guides.bracketPairs",
            Value::Bool(value.as_bool().unwrap_or(value.is_string())),
        );
    }
    if let Some(value) = flat("editor.quickSuggestions") {
        let on = value.as_bool().unwrap_or_else(|| {
            value.as_object().is_some_and(|members| {
                members
                    .values()
                    .any(|item| *item == Value::Bool(true) || item.as_str() == Some("on"))
            })
        });
        out.insert("quickSuggestions".into(), Value::Bool(on));
    }
    if let Some(value) = flat("editor.wordBasedSuggestions") {
        out.insert(
            "wordBasedSuggestions".into(),
            Value::Bool(value.as_bool().unwrap_or(value.as_str() != Some("off"))),
        );
    }
    if let Some(value) = flat("editor.cursorSmoothCaretAnimation") {
        if let Some(flag) = value.as_bool() {
            out.insert("cursorSmoothCaretAnimation".into(), json!(if flag { "on" } else { "off" }));
        } else if let Some(text) =
            value.as_str().filter(|text| ["off", "explicit", "on"].contains(text))
        {
            out.insert("cursorSmoothCaretAnimation".into(), json!(text));
        }
    }
    match flat("files.autoSave").and_then(Value::as_str) {
        Some("off") => {
            out.insert("autoSave".into(), json!("off"));
        }
        // cmux saves after a pause or when the page hides; VS Code's focus and window modes are closest to that.
        Some("afterDelay" | "onFocusChange" | "onWindowChange") => {
            out.insert("autoSave".into(), json!("afterDelay"));
        }
        _ => {}
    }
    if let Some(delay) = flat("files.autoSaveDelay")
        .and_then(Value::as_f64)
        .filter(|x| (100.0..=60_000.0).contains(x))
    {
        out.insert("autoSaveDelay".into(), number_value(delay.round()));
    }
    for key in ["trimTrailingWhitespace", "insertFinalNewline"] {
        if let Some(flag) = flat(&format!("files.{key}")).and_then(Value::as_bool) {
            out.insert(key.into(), Value::Bool(flag));
        }
    }
    let mut languages = Map::new();
    for (key, block) in root.iter().filter(|(key, _)| key.starts_with('[')) {
        let Some(members) = block.as_object() else { continue };
        let mut language = Map::new();
        for name in LANGUAGE_KEYS {
            let Some(value) = members.get(&format!("editor.{name}")) else { continue };
            let mapped = if name == "rulers" { rulers(value) } else { vscode_value(name, value) };
            if let Some(mapped) = mapped {
                language.insert(name.into(), mapped);
            }
        }
        if language.is_empty() {
            continue;
        }
        // "[typescript][javascript]" names more than one language.
        for id in key.split(['[', ']']).filter(|id| !id.is_empty() && is_language_id(id)) {
            let id = id.to_lowercase();
            let merged = merged(languages.get(&id), &language);
            languages.insert(id, merged);
        }
    }
    if !languages.is_empty() {
        out.insert("languages".into(), Value::Object(languages));
    }
    if let Some(bindings) =
        keybindings.map(vscode_keybindings).filter(|bindings| !bindings.is_empty())
    {
        out.insert("keybindings".into(), Value::Array(bindings));
    }
    Value::Object(out)
}

/// A VS Code value in the shape the row for `key` accepts, or `None`.
fn vscode_value(key: &str, value: &Value) -> Option<Value> {
    let mut path = vec!["editor".to_owned()];
    path.extend(split_dots(key));
    let Some(row) = Schema::embedded().row_at(&path) else {
        return Some(value.clone());
    };
    let domains = Domains::default();
    if schema::accepts(row, value, &domains).is_ok() {
        return Some(value.clone());
    }
    // Numbers out of a row's range keep the default rather than load with a warning.
    if let (Kind::Number(_), Some(number)) = (&row.kind, value.as_f64()) {
        let rounded = number_value(number.round());
        return schema::accepts(row, &rounded, &domains).is_ok().then_some(rounded);
    }
    None
}

/// Swift `Double(String)`: the decimal forms Swift and Rust both read.
fn parse_double(text: &str) -> Option<f64> {
    text.parse::<f64>().ok()
}

/// The weight the row offers nearest to `value` (a number, a number string, `normal` or `bold`).
fn font_weight(value: &Value) -> Option<Value> {
    if let Some(text) = value.as_str().filter(|text| *text == "normal" || *text == "bold") {
        return Some(json!(text));
    }
    let number = value.as_f64().or_else(|| value.as_str().and_then(parse_double))?;
    let choices =
        [(300.0, "300"), (400.0, "normal"), (500.0, "500"), (600.0, "600"), (700.0, "bold")];
    // The first nearest, as Swift's `min(by:)` (NaN keeps the first).
    let mut best = choices[0];
    for choice in &choices[1..] {
        if (choice.0 - number).abs() < (best.0 - number).abs() {
            best = *choice;
        }
    }
    Some(json!(best.1))
}

/// Ruler columns from numbers or VS Code's `{column, color}`: 1...1000, the first 8.
fn rulers(value: &Value) -> Option<Value> {
    let items = value.as_array()?;
    let columns = items
        .iter()
        .filter_map(|item| item.as_f64().or_else(|| get(item, "column").and_then(Value::as_f64)))
        .filter(|column| (1.0..=1000.0).contains(column))
        .take(8)
        .map(|column| number_value(column.round()))
        .collect();
    Some(Value::Array(columns))
}

/// Editor command bindings from `keybindings.json`: Monaco's command ids and
/// their removals (`-editor.action.x`); workbench commands are not the editor's.
fn vscode_keybindings(value: &Value) -> Vec<Value> {
    let Some(items) = value.as_array() else { return Vec::new() };
    items
        .iter()
        .take(500)
        .filter_map(|item| {
            let key = get(item, "key")?.as_str()?;
            let command =
                get(item, "command")?.as_str().filter(|command| is_editor_command(command))?;
            let mut entry = Map::new();
            entry.insert("key".into(), json!(key));
            entry.insert("command".into(), json!(command));
            if let Some(when) = get(item, "when").and_then(Value::as_str)
                && !when.is_empty()
                && char_count(when) <= 300
            {
                entry.insert("when".into(), json!(when));
            }
            Some(Value::Object(entry))
        })
        .collect()
}

fn is_editor_command(command: &str) -> bool {
    let id = command.strip_prefix('-').unwrap_or(command);
    if id.len() > 128
        || !id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        return false;
    }
    id.starts_with("editor.") || MONACO_COMMANDS.contains(&id)
}

// MARK: Zed

/// Zed actions with a Monaco command of the same meaning.
const ZED_ACTIONS: [(&str, &str); 32] = [
    ("editor::SelectAllMatches", "editor.action.selectHighlights"),
    ("editor::SelectNext", "editor.action.addSelectionToNextFindMatch"),
    ("editor::SelectPrevious", "editor.action.addSelectionToPreviousFindMatch"),
    ("editor::ToggleComments", "editor.action.commentLine"),
    ("editor::MoveLineUp", "editor.action.moveLinesUpAction"),
    ("editor::MoveLineDown", "editor.action.moveLinesDownAction"),
    ("editor::DuplicateLineDown", "editor.action.copyLinesDownAction"),
    ("editor::DuplicateLineUp", "editor.action.copyLinesUpAction"),
    ("editor::DeleteLine", "editor.action.deleteLines"),
    ("editor::AddSelectionAbove", "editor.action.insertCursorAbove"),
    ("editor::AddSelectionBelow", "editor.action.insertCursorBelow"),
    ("editor::Fold", "editor.fold"),
    ("editor::UnfoldLines", "editor.unfold"),
    ("editor::FoldAll", "editor.foldAll"),
    ("editor::UnfoldAll", "editor.unfoldAll"),
    ("editor::ToggleSoftWrap", "editor.action.toggleWordWrap"),
    ("editor::Indent", "editor.action.indentLines"),
    ("editor::Outdent", "editor.action.outdentLines"),
    ("editor::NewlineBelow", "editor.action.insertLineAfter"),
    ("editor::NewlineAbove", "editor.action.insertLineBefore"),
    ("editor::SelectLargerSyntaxNode", "editor.action.smartSelect.expand"),
    ("editor::SelectSmallerSyntaxNode", "editor.action.smartSelect.shrink"),
    ("editor::MoveToEnclosingBracket", "editor.action.jumpToBracket"),
    ("editor::ConvertToUpperCase", "editor.action.transformToUppercase"),
    ("editor::ConvertToLowerCase", "editor.action.transformToLowercase"),
    ("editor::SortLinesCaseSensitive", "editor.action.sortLinesAscending"),
    ("editor::JoinLines", "editor.action.joinLines"),
    ("editor::Format", "editor.action.formatDocument"),
    ("editor::SelectLine", "editor.action.expandLineSelection"),
    ("editor::ShowCompletions", "editor.action.triggerSuggest"),
    ("buffer_search::Deploy", "actions.find"),
    ("go_to_line::Toggle", "editor.action.gotoLine"),
];

/// The `editor` section for a Zed `settings.json` and its `keymap.json` (`None` when absent).
pub fn zed(settings: &Value, keymap: Option<&Value>) -> Value {
    let mut out = Map::new();
    let at = |key: &str| get(settings, key);
    if let Some(family) =
        at("buffer_font_family").and_then(Value::as_str).filter(|family| !family.is_empty())
    {
        out.insert("fontFamily".into(), json!(family));
    }
    if let Some(size) =
        at("buffer_font_size").and_then(Value::as_f64).filter(|x| (6.0..=72.0).contains(x))
    {
        out.insert("fontSize".into(), number_value(size));
    }
    if let Some(weight) = at("buffer_font_weight").and_then(font_weight) {
        out.insert("fontWeight".into(), weight);
    }
    match at("buffer_line_height") {
        Some(Value::String(text)) if text == "comfortable" => {
            out.insert("lineHeight".into(), number_value(1.618));
        }
        Some(Value::String(text)) if text == "standard" => {
            out.insert("lineHeight".into(), number_value(1.3));
        }
        Some(value) => {
            if let Some(custom) =
                get(value, "custom").and_then(Value::as_f64).filter(|x| *x > 0.0 && *x < 8.0)
            {
                out.insert("lineHeight".into(), number_value(custom));
            }
        }
        None => {}
    }
    // Zed's font features `{"calt": false}` turn ligatures off.
    if let Some(calt) = at("buffer_font_features")
        .and_then(|features| get(features, "calt"))
        .and_then(Value::as_bool)
    {
        out.insert("fontLigatures".into(), Value::Bool(calt));
    }
    zed_language(settings, &mut out);
    if at("relative_line_numbers").and_then(Value::as_bool) == Some(true) {
        out.insert("lineNumbers".into(), json!("relative"));
    }
    if at("gutter").and_then(|gutter| get(gutter, "line_numbers")).and_then(Value::as_bool)
        == Some(false)
    {
        out.insert("lineNumbers".into(), json!("off"));
    }
    if let Some(whitespace) = at("show_whitespaces")
        .and_then(Value::as_str)
        .filter(|text| ["none", "boundary", "selection", "trailing", "all"].contains(text))
    {
        out.insert("renderWhitespace".into(), json!(whitespace));
    }
    if let Some(blink) = at("cursor_blink").and_then(Value::as_bool) {
        out.insert("cursorBlinking".into(), json!(if blink { "blink" } else { "solid" }));
    }
    let style = match at("cursor_shape").and_then(Value::as_str) {
        Some("bar") => Some("line"),
        Some("block") => Some("block"),
        Some("underline") => Some("underline"),
        Some("hollow") => Some("block-outline"),
        _ => None,
    };
    if let Some(style) = style {
        out.insert("cursorStyle".into(), json!(style));
    }
    match at("minimap").and_then(|minimap| get(minimap, "show")).and_then(Value::as_str) {
        Some("always" | "auto") => set(&mut out, "minimap.enabled", Value::Bool(true)),
        Some("never") => set(&mut out, "minimap.enabled", Value::Bool(false)),
        _ => {}
    }
    if let Some(beyond) = at("scroll_beyond_last_line").and_then(Value::as_str) {
        out.insert("scrollBeyondLastLine".into(), Value::Bool(beyond != "off"));
    }
    if let Some(flag) = at("remove_trailing_whitespace_on_save").and_then(Value::as_bool) {
        out.insert("trimTrailingWhitespace".into(), Value::Bool(flag));
    }
    if let Some(flag) = at("ensure_final_newline_on_save").and_then(Value::as_bool) {
        out.insert("insertFinalNewline".into(), Value::Bool(flag));
    }
    match at("autosave") {
        Some(Value::String(text)) => {
            out.insert("autoSave".into(), json!(if text == "off" { "off" } else { "afterDelay" }));
        }
        Some(value) => {
            let delay = get(value, "after_delay")
                .and_then(|after| get(after, "milliseconds"))
                .and_then(Value::as_f64);
            if let Some(delay) = delay {
                out.insert("autoSave".into(), json!("afterDelay"));
                if (100.0..=60_000.0).contains(&delay) {
                    out.insert("autoSaveDelay".into(), number_value(delay.round()));
                }
            }
        }
        None => {}
    }
    if let Some(languages) = at("languages").and_then(Value::as_object) {
        let mut mapped = Map::new();
        for (name, block) in languages {
            let mut language = Map::new();
            zed_language(block, &mut language);
            language.retain(|key, _| LANGUAGE_KEYS.contains(&key.as_str()));
            let id = name.to_lowercase().replace(' ', "");
            if !language.is_empty() && is_language_id(&id) {
                mapped.insert(id, Value::Object(language));
            }
        }
        if !mapped.is_empty() {
            out.insert("languages".into(), Value::Object(mapped));
        }
    }
    if let Some(bindings) = keymap.map(zed_keybindings).filter(|bindings| !bindings.is_empty()) {
        out.insert("keybindings".into(), Value::Array(bindings));
    }
    Value::Object(out)
}

/// The keys a Zed settings object and a Zed language block share.
fn zed_language(settings: &Value, out: &mut Map<String, Value>) {
    let at = |key: &str| get(settings, key);
    if let Some(size) = at("tab_size").and_then(Value::as_f64).filter(|x| (1.0..=16.0).contains(x))
    {
        out.insert("tabSize".into(), number_value(size.round()));
    }
    if let Some(hard) = at("hard_tabs").and_then(Value::as_bool) {
        out.insert("insertSpaces".into(), Value::Bool(!hard));
    }
    if let Some(length) =
        at("preferred_line_length").and_then(Value::as_f64).filter(|x| (10.0..=1000.0).contains(x))
    {
        out.insert("wordWrapColumn".into(), number_value(length.round()));
    }
    let wrap = match at("soft_wrap").and_then(Value::as_str) {
        Some("none") => Some("off"),
        Some("editor_width" | "prefer_line") => Some("on"),
        Some("preferred_line_length") => Some("wordWrapColumn"),
        Some("bounded") => Some("bounded"),
        _ => None,
    };
    if let Some(wrap) = wrap {
        out.insert("wordWrap".into(), json!(wrap));
    }
    if let Some(guides) = at("wrap_guides").and_then(rulers) {
        out.insert("rulers".into(), guides);
    }
    if let Some(format) = at("format_on_save") {
        let on =
            format.as_bool().unwrap_or_else(|| format.as_str().is_some_and(|text| text != "off"));
        out.insert("formatOnSave".into(), Value::Bool(on));
    }
}

/// Bindings of the editor's contexts (`Editor`) whose actions have a Monaco command.
fn zed_keybindings(value: &Value) -> Vec<Value> {
    let actions: BTreeMap<&str, &str> = ZED_ACTIONS.into_iter().collect();
    let mut out = Vec::new();
    for block in value.as_array().map(Vec::as_slice).unwrap_or_default() {
        if let Some(context) = get(block, "context").and_then(Value::as_str)
            && !context.contains("Editor")
        {
            continue;
        }
        let Some(bindings) = get(block, "bindings").and_then(Value::as_object) else { continue };
        // serde_json's map is sorted by key, as Swift sorts them.
        for (key, action) in bindings {
            let name = action.as_str().or_else(|| action.as_array()?.first()?.as_str());
            let Some(command) = name.and_then(|name| actions.get(name)) else { continue };
            out.push(json!({"key": key, "command": command}));
            if out.len() >= 500 {
                return out;
            }
        }
    }
    out
}

// MARK: Helpers

/// 1-64 ASCII letters, digits or `+#._-`.
pub fn is_language_id(id: &str) -> bool {
    !id.is_empty()
        && id.chars().count() <= 64
        && id.chars().all(|c| c.is_ascii_alphanumeric() || "+#._-".contains(c))
}

/// Sets a dotted key (`minimap.enabled`) in `section`, keeping the object's other members.
fn set(section: &mut Map<String, Value>, key: &str, value: Value) {
    let path = split_dots(key);
    let root = Value::Object(std::mem::take(section));
    if let Value::Object(members) = with_value(&root, value, &path) {
        *section = members;
    }
}

/// `base` with `overlay`'s members on top, objects merged member by member.
fn merged(base: Option<&Value>, overlay: &Map<String, Value>) -> Value {
    let mut members = base.and_then(Value::as_object).cloned().unwrap_or_default();
    for (key, value) in overlay {
        let next = match (value.as_object(), members.get(key)) {
            (Some(object), Some(existing)) if existing.is_object() => {
                merged(Some(existing), object)
            }
            _ => value.clone(),
        };
        members.insert(key.clone(), next);
    }
    Value::Object(members)
}

/// The code editor's section: `imported` under `own` (a key set in
/// cmux-next.json wins, objects merged member by member).
pub fn section(imported: &Value, own: &Value) -> Value {
    let base = if imported.is_object() { imported.clone() } else { Value::Object(Map::new()) };
    let empty = Map::new();
    merged(Some(&base), own.as_object().unwrap_or(&empty))
}

/// What copying `imported` into cmux-next.json writes: every `editor` row
/// (but `editor.importFrom`) whose key `imported` has, that its row accepts,
/// and that `file` (the cmux-next.json root) does not set yet. Each is a
/// `(row path, value)` in schema order.
#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
pub fn copy_writes(imported: &Value, file: &Value) -> Vec<(Vec<String>, Value)> {
    let imported = canonical(imported.clone());
    let domains = Domains::default();
    Schema::embedded()
        .rows_in(Some("editor"))
        .filter(|row| row.key != "editor.importFrom")
        .filter_map(|row| {
            let value = value_at(&imported, &row.path[1..])?;
            if schema::accepts(row, value, &domains).is_err() || value_at(file, &row.path).is_some()
            {
                return None;
            }
            Some((row.path.clone(), value.clone()))
        })
        .collect()
}

/// A code editor page toggle (PAGE-PREFS): the catalog action and the key it writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Toggle {
    pub action: &'static str,
    pub key: &'static str,
}

/// Opt-Z (Word Wrap), then Toggle Editor Minimap.
pub const TOGGLES: [Toggle; 2] = [
    Toggle { action: "toggleFileEditorWordWrap", key: "editor.wordWrap" },
    Toggle { action: "toggleFileEditorMinimap", key: "editor.minimap.enabled" },
];

/// The toggle of `action` and the value it writes when the page's editor
/// section is `section`: `editor.wordWrap` between "off" and "on" (any other
/// mode counts as on); `editor.minimap.enabled` read as `true`/`false` or
/// Monaco's `{enabled}` form.
pub fn toggle_next(action: &str, section: Option<&Value>) -> Option<(Toggle, Value)> {
    let toggle = TOGGLES.into_iter().find(|toggle| toggle.action == action)?;
    let value = if toggle.action == "toggleFileEditorWordWrap" {
        let mode = section
            .and_then(|section| get(section, "wordWrap"))
            .and_then(Value::as_str)
            .unwrap_or("off");
        json!(if mode == "off" { "on" } else { "off" })
    } else {
        let minimap = section.and_then(|section| get(section, "minimap"));
        let on = minimap
            .and_then(Value::as_bool)
            .or_else(|| {
                minimap.and_then(|minimap| get(minimap, "enabled")).and_then(Value::as_bool)
            })
            .unwrap_or(false);
        Value::Bool(!on)
    };
    Some((toggle, value))
}

#[cfg(test)]
#[path = "editor_import_tests.rs"]
mod tests;
