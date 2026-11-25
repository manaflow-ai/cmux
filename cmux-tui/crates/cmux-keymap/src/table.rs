//! The embedded keymap table (`schemas/keymap/key-styles.json`), parsed once.

use crate::{KeyStyle, ListCommand, Stroke};
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::OnceLock;

/// `schemas/keymap/key-styles.json`, the one table the web surfaces import too.
pub const KEY_STYLES_JSON: &str = include_str!("../../../../schemas/keymap/key-styles.json");

#[derive(Deserialize)]
struct StylesFile {
    commands: Vec<String>,
    styles: HashMap<String, Vec<RowFile>>,
    keys: Vec<KeyFile>,
}

#[derive(Deserialize)]
struct RowFile {
    keys: Vec<String>,
    command: String,
    #[serde(default, rename = "inText")]
    in_text: bool,
}

#[derive(Deserialize)]
struct KeyFile {
    code: String,
    qwerty: String,
    mac: u16,
}

/// One list-layer row: a stroke sequence and the command it gives.
#[derive(Debug, Clone)]
pub(crate) struct Row {
    pub strokes: Vec<Stroke>,
    pub command: ListCommand,
    pub in_text: bool,
}

#[derive(Debug, Clone)]
pub(crate) struct PhysicalKey {
    pub code: String,
    pub qwerty: String,
    pub mac: u16,
}

#[derive(Debug, Default)]
pub(crate) struct Table {
    pub standard: Vec<Row>,
    pub vim: Vec<Row>,
    pub emacs: Vec<Row>,
    pub keys: Vec<PhysicalKey>,
}

impl Table {
    pub fn rows(&self, style: KeyStyle) -> &[Row] {
        match style {
            KeyStyle::Standard => &self.standard,
            KeyStyle::Vim => &self.vim,
            KeyStyle::Emacs => &self.emacs,
        }
    }
}

/// Parses the table, naming every row, stroke or command it cannot read.
fn parse() -> Result<Table, Vec<String>> {
    let file: StylesFile =
        serde_json::from_str(KEY_STYLES_JSON).map_err(|e| vec![format!("key-styles.json: {e}")])?;
    let mut problems = Vec::new();
    let ids: Vec<&str> = ListCommand::ALL.iter().map(|c| c.id()).collect();
    if file.commands.iter().map(String::as_str).ne(ids.iter().copied()) {
        problems.push(format!(
            "commands {:?} differ from ListCommand::ALL {ids:?}; keep them in one order",
            file.commands
        ));
    }
    let mut style_rows = |name: &str| -> Vec<Row> {
        let Some(rows) = file.styles.get(name) else {
            problems.push(format!("styles.{name} is missing"));
            return Vec::new();
        };
        let mut out = Vec::new();
        for row in rows {
            let Some(command) = ListCommand::from_id(&row.command) else {
                problems.push(format!("styles.{name}: unknown command {:?}", row.command));
                continue;
            };
            let strokes: Option<Vec<Stroke>> = row.keys.iter().map(|k| Stroke::parse(k)).collect();
            match strokes {
                Some(strokes) if !strokes.is_empty() => {
                    out.push(Row { strokes, command, in_text: row.in_text });
                }
                _ => problems.push(format!("styles.{name}: unreadable keys {:?}", row.keys)),
            }
        }
        out
    };
    let standard = style_rows("standard");
    let vim = style_rows("vim");
    let emacs = style_rows("emacs");
    for name in file.styles.keys() {
        if KeyStyle::from_setting_exact(name).is_none() {
            problems.push(format!("styles.{name} is not a KeyStyle"));
        }
    }
    let keys = file
        .keys
        .into_iter()
        .map(|k| PhysicalKey { code: k.code, qwerty: k.qwerty, mac: k.mac })
        .collect();
    let table = Table { standard, vim, emacs, keys };
    if problems.is_empty() { Ok(table) } else { Err(problems) }
}

/// The parsed table. An unreadable table (which [`check_table`] and the tests catch) leaves
/// every style empty and no physical keys, so keys pass to the surface instead of panicking.
pub(crate) fn table() -> &'static Table {
    static TABLE: OnceLock<Table> = OnceLock::new();
    TABLE.get_or_init(|| parse().unwrap_or_default())
}

/// Whether the embedded table parses completely: every style, command and stroke. The tests
/// call it; a problem here means the JSON and this crate disagree.
pub fn check_table() -> Result<(), Vec<String>> {
    parse().map(|_| ())
}
