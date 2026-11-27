//! A Home reply's pipe tables, as JSON ops for the Mac app's Home transcript
//! ([`cmux_message_preview::home_table`]):
//! - `home_table.segments` `{text}` answers `{segments}`: each `{text}` or
//!   `{table, raw}`, a table being `{header, alignments, rows}` (alignments
//!   `leading`, `center` or `trailing`).
//! - `home_table.cell` `{markdown}` answers `{text, bold, links, images}`:
//!   `bold` as `[location, length]` pairs in UTF-16 code units, `images` as
//!   `{alt, source}`.
//! - `home_table.plan_card` `{table}` answers `{rows}` (each `{key?, title,
//!   owner?, owner_note?, pull_requests, written?}`) or `{}` when the table is
//!   not an assignment list.
//! - `home_table.columns` `{natural, available}` answers `{widths}`.
//! - `home_table.attachment_hashes` `{text}` answers `{hashes}`, sorted.
//! - `home_table.pull_request` `{link}` answers `{key, url}` or `{}`.

use cmux_message_preview::home_table::{self, Alignment, Segment, Table};
use serde_json::{Map, Value, json};

use super::{OpError, string};

/// Runs a `home_table.*` op; `None` for another area's op.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "home_table.segments" => segments(request),
        "home_table.cell" => cell(request),
        "home_table.plan_card" => plan_card(request),
        "home_table.columns" => columns(request),
        "home_table.attachment_hashes" => string(request, "text")
            .map(|text| json!({ "hashes": home_table::attachment_hashes(text) })),
        "home_table.pull_request" => pull_request(request),
        _ => return None,
    })
}

fn table_json(table: &Table) -> Value {
    json!({
        "header": table.header,
        "alignments": table.alignments.iter().map(|a| a.name()).collect::<Vec<_>>(),
        "rows": table.rows,
    })
}

fn strings(value: &Value, what: &str) -> Result<Vec<String>, OpError> {
    let invalid = || OpError::Invalid(format!("expected `{what}` to be an array of strings"));
    value
        .as_array()
        .ok_or_else(invalid)?
        .iter()
        .map(|s| s.as_str().map(str::to_owned).ok_or_else(invalid))
        .collect()
}

fn table_of(value: Option<&Value>) -> Result<Table, OpError> {
    let value = value.ok_or_else(|| OpError::Invalid("expected an object `table`".into()))?;
    let header = strings(value.get("header").unwrap_or(&Value::Null), "table.header")?;
    let rows = value
        .get("rows")
        .and_then(Value::as_array)
        .ok_or_else(|| OpError::Invalid("expected `table.rows` to be an array".into()))?
        .iter()
        .map(|row| {
            // Each row padded or cut to the header, as the splitter gives it.
            let mut row = strings(row, "table.rows[]")?;
            row.resize(header.len(), String::new());
            Ok(row)
        })
        .collect::<Result<Vec<_>, OpError>>()?;
    let alignments = vec![Alignment::Leading; header.len()];
    Ok(Table { header, alignments, rows })
}

fn segments(request: &Value) -> Result<Value, OpError> {
    let text = string(request, "text")?;
    let segments: Vec<Value> = home_table::segments(text)
        .iter()
        .map(|segment| match segment {
            Segment::Text(text) => json!({ "text": text }),
            Segment::Table { table, raw } => json!({ "table": table_json(table), "raw": raw }),
        })
        .collect();
    Ok(json!({ "segments": segments }))
}

fn cell(request: &Value) -> Result<Value, OpError> {
    let cell = home_table::cell(string(request, "markdown")?);
    Ok(json!({
        "text": cell.text,
        "bold": cell.bold.iter().map(|&(location, length)| [location, length]).collect::<Vec<_>>(),
        "links": cell.links,
        "images": cell.images.iter().map(|i| json!({ "alt": i.alt, "source": i.source })).collect::<Vec<_>>(),
    }))
}

fn plan_card(request: &Value) -> Result<Value, OpError> {
    let table = table_of(request.get("table"))?;
    let Some(rows) = home_table::plan_card(&table) else { return Ok(json!({})) };
    let rows: Vec<Value> = rows
        .into_iter()
        .map(|row| {
            let mut out = Map::new();
            if let Some(key) = row.key {
                out.insert("key".into(), key.into());
            }
            out.insert("title".into(), row.title.into());
            if let Some(owner) = row.owner {
                out.insert("owner".into(), owner.into());
            }
            if let Some(note) = row.owner_note {
                out.insert("owner_note".into(), note.into());
            }
            out.insert("pull_requests".into(), row.pull_requests.into());
            if let Some(written) = row.written {
                out.insert("written".into(), written.name().into());
            }
            Value::Object(out)
        })
        .collect();
    Ok(json!({ "rows": rows }))
}

fn columns(request: &Value) -> Result<Value, OpError> {
    let natural = request
        .get("natural")
        .and_then(Value::as_array)
        .and_then(|a| a.iter().map(Value::as_f64).collect::<Option<Vec<_>>>())
        .ok_or_else(|| OpError::Invalid("expected `natural` to be an array of numbers".into()))?;
    let available = request
        .get("available")
        .and_then(Value::as_f64)
        .ok_or_else(|| OpError::Invalid("expected a number `available`".into()))?;
    Ok(json!({ "widths": home_table::column_widths(&natural, available) }))
}

fn pull_request(request: &Value) -> Result<Value, OpError> {
    let link = string(request, "link")?;
    Ok(match (home_table::pull_request_key(link), home_table::pull_request_url(link)) {
        (Some(key), Some(url)) => json!({ "key": key, "url": url }),
        _ => json!({}),
    })
}
