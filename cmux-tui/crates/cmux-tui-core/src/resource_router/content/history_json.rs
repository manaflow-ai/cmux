//! Public JSON for `terminal.history.read` rows: one object per row with its
//! styled runs, or one plain run when the caller asked for unstyled text.

use ghostty_vt::{Cell, Rgb, StyledRun, UnderlineStyle, rows_to_runs};
use serde_json::{Map, Value, json};

pub(super) fn history_rows_json(rows: &[Vec<Cell>], styled: bool) -> Vec<Value> {
    let runs = rows_to_runs(rows);
    runs.iter()
        .enumerate()
        .map(|(row, runs)| {
            let runs = if styled {
                runs.iter().map(styled_run_json).collect()
            } else {
                vec![json!({
                    "text":runs.iter().map(|run| run.text.as_str()).collect::<String>(),
                    "fg":null,
                    "bg":null,
                    "attrs":0,
                })]
            };
            json!({"row":row,"runs":runs})
        })
        .collect()
}

fn styled_run_json(run: &StyledRun) -> Value {
    let mut value = Map::from_iter([
        ("text".to_string(), json!(run.text)),
        ("fg".to_string(), json!(run.fg.map(rgb_hex))),
        ("bg".to_string(), json!(run.bg.map(rgb_hex))),
        ("attrs".to_string(), json!(u32::from(run.attrs))),
    ]);
    if let Some(underline) = run.underline {
        let style = match underline {
            UnderlineStyle::Single => "single",
            UnderlineStyle::Double => "double",
            UnderlineStyle::Curly => "curly",
            UnderlineStyle::Dotted => "dotted",
            UnderlineStyle::Dashed => "dashed",
        };
        value.insert("underline".to_string(), json!(style));
    }
    if let Some(width_hint) = run.width_hint {
        value.insert("width_hint".to_string(), json!(width_hint));
    }
    Value::Object(value)
}

fn rgb_hex(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}
