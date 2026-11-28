//! `schema.rows`: many rows' reads in one call, so a Settings page or the Command Palette renders
//! with one round trip instead of one per row and question.
//!
//! `{root, stored_root?, keys?, section?, arts?, palette?}` answers `{rows}` in the order of
//! `keys` (else schema order, only `section`'s rows when it is given). Each row is
//! `{key, stored, effective, customized, toggled, inherited}`, as `schema.stored`,
//! `schema.effective`, `schema.customized`, `schema.toggled` and `schema.inherited` answer them:
//! `stored` and `customized` read `stored_root` (the file as written; `root` when absent), the
//! rest read `root` (what applies).
//!
//! With `palette` `{theme_colors?, selections?, current?}`, each row adds `options` and
//! `summary` as `schema.palette_options` answers them, for the row's effective value, or for
//! `current[KEY]` when the app has a value pending for it (null: unset). `selections` maps a
//! background value to the app's resolution of it (`{id, title}`, or null for none).
//!
//! When any row needs what only the app knows, the op answers `{need: {arts, selections}}`, every
//! old painting id and background value at once; the app asks again with `arts` and
//! `palette.selections` filled in.

use std::collections::BTreeSet;

use serde_json::{Map, Value, json};

use super::{
    OpError, PaletteContext, PaletteOption, Read, arts, effective, inherited, is_customized,
    palette_options, palette_summary, root, selection_of, stored, theme_colors, toggled,
};
use crate::schema::{Row, Schema};

/// What only the app can answer, gathered over every row.
#[derive(Debug, Default)]
struct Needs {
    arts: BTreeSet<String>,
    selections: BTreeSet<String>,
}

impl Needs {
    fn add(&mut self, need: &Value) {
        if let Some(id) = need.get("art").and_then(Value::as_str) {
            self.arts.insert(id.to_owned());
        }
        if let Some(raw) = need.get("selection").and_then(Value::as_str) {
            self.selections.insert(raw.to_owned());
        }
    }

    fn is_empty(&self) -> bool {
        self.arts.is_empty() && self.selections.is_empty()
    }
}

/// The palette half of the request.
struct Palette<'a> {
    context: PaletteContext,
    selections: Map<String, Value>,
    current: Option<&'a Map<String, Value>>,
}

impl<'a> Palette<'a> {
    fn of(request: &'a Value) -> Result<Option<Palette<'a>>, OpError> {
        let palette = match request.get("palette") {
            None | Some(Value::Null) => return Ok(None),
            Some(palette @ Value::Object(_)) => palette,
            Some(_) => return Err(OpError::Invalid("expected an object `palette`".to_owned())),
        };
        let object = |name: &str| match palette.get(name) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::Object(members)) => Ok(Some(members)),
            Some(_) => Err(OpError::Invalid(format!("expected an object `palette.{name}`"))),
        };
        let selections = object("selections")?.cloned().unwrap_or_default();
        let current = object("current")?;
        let context = PaletteContext { theme_colors: theme_colors(palette)?, ..Default::default() };
        Ok(Some(Palette { context, selections, current }))
    }
}

/// The rows the request names: `keys` in order, else `section`'s rows or every row.
fn requested(request: &Value) -> Result<Vec<&'static Row>, OpError> {
    let schema = Schema::embedded();
    match request.get("keys") {
        None | Some(Value::Null) => {}
        Some(Value::Array(keys)) => {
            return keys
                .iter()
                .map(|key| {
                    let key = key
                        .as_str()
                        .ok_or_else(|| OpError::Invalid("expected `keys` as strings".to_owned()))?;
                    schema.row(key).ok_or_else(|| OpError::Invalid(format!("no setting `{key}`")))
                })
                .collect();
        }
        Some(_) => return Err(OpError::Invalid("expected an array `keys`".to_owned())),
    }
    let section = request.get("section").and_then(Value::as_str);
    Ok(schema
        .rows
        .iter()
        .filter(|row| section.is_none_or(|section| row.section == section))
        .collect())
}

#[allow(
    clippy::indexing_slicing,
    reason = "positions come from the value's own length or search, so they are in range"
)]
pub fn call(request: &Value) -> Result<Value, OpError> {
    let rows = requested(request)?;
    let root = root(request);
    let stored_root = request.get("stored_root").unwrap_or(root);
    let arts = arts(request)?;
    let mut palette = Palette::of(request)?;
    let mut needs = Needs::default();
    let mut answers = Vec::with_capacity(rows.len());
    for row in rows {
        let file = match stored(row, stored_root, arts) {
            Read::Value(value) => value,
            Read::Need(need) => {
                needs.add(&need);
                continue;
            }
        };
        let applied = match effective(row, root, arts) {
            Read::Value(value) => value,
            Read::Need(need) => {
                needs.add(&need);
                continue;
            }
        };
        let inherited = inherited(row, root);
        let mut answer = json!({
            "key": row.key,
            "stored": file,
            "effective": applied,
            "customized": is_customized(row, file.as_ref()),
            "toggled": toggled(row, applied.as_ref()),
            "inherited": inherited,
        });
        if let Some(palette) = palette.as_mut() {
            let current = match palette.current.and_then(|current| current.get(&row.key)) {
                Some(pending) => (!pending.is_null()).then_some(pending),
                None => applied.as_ref(),
            };
            palette.context.inherited = inherited;
            palette.context.selection = match current.and_then(Value::as_str) {
                Some(raw) => match palette.selections.get(raw) {
                    Some(selection) => Some(selection_of(selection)?),
                    None => None,
                },
                None => None,
            };
            match palette_options(row, current, &palette.context) {
                Ok(options) => {
                    answer["summary"] = json!(palette_summary(row, current, &options));
                    answer["options"] =
                        Value::Array(options.iter().map(PaletteOption::to_json).collect());
                }
                Err(need) => needs.add(&need),
            }
        }
        answers.push(answer);
    }
    if !needs.is_empty() {
        return Ok(json!({ "need": { "arts": needs.arts, "selections": needs.selections } }));
    }
    Ok(json!({ "rows": answers }))
}

#[cfg(test)]
#[path = "schema_rows_tests.rs"]
mod tests;
