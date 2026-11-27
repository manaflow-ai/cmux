//! The look a settings root shows, written as a theme file: every look key
//! the root sets is a live entry with that value, and every other look key
//! is a comment with its default, so the file documents the whole look and
//! applying it changes nothing (each live value is already the root's).

use serde_json::Value;

use super::{SCHEMA_FILE_NAME, is_look};
use crate::domains::Domains;
use crate::schema::{Schema, accepts};
use crate::value::value_at;

/// What [`render`] writes besides the look.
#[derive(Debug, Clone, Default)]
pub struct RenderOptions<'a> {
    /// The file's `"name"`.
    pub name: &'a str,
    /// The file's `"description"`; none when empty.
    pub description: &'a str,
}

/// `root`'s look as a theme file (JSONC).
pub fn render(
    root: &Value,
    schema: &Schema,
    domains: &Domains,
    options: &RenderOptions<'_>,
) -> String {
    let mut out = String::new();
    out.push_str(
        "// A cmux theme file: the whole look of the app in one file. Save it and the running app\n\
         // repaints at once, on the Mac and on a paired iPhone. Live entries are this look's own\n\
         // values; a commented entry shows the default: remove its // to change it. A value cmux\n\
         // refuses is named in Settings and the rest still applies. `cmux theme --help` has more.\n",
    );
    out.push_str("{\n");
    out.push_str(&format!("  \"$schema\": {},\n", quote(&format!("./{SCHEMA_FILE_NAME}"))));
    out.push_str(&format!("  \"name\": {},\n", quote(options.name)));
    if !options.description.is_empty() {
        out.push_str(&format!("  \"description\": {},\n", quote(options.description)));
    }
    let mut group = String::new();
    for row in schema.rows_in(None).filter(|row| is_look(row)) {
        if row.group.text != group {
            group.clone_from(&row.group.text);
            out.push_str(&format!("\n  // {}\n", one_line(&group)));
        }
        let title = row.summary.as_ref().map_or(&row.title.text, |summary| &summary.text);
        match value_at(root, &row.path).filter(|value| accepts(row, value, domains).is_ok()) {
            Some(value) => {
                out.push_str(&format!(
                    "  {}: {},  // {}\n",
                    quote(&row.key),
                    json(value),
                    one_line(title)
                ));
            }
            None => {
                let default = match (&row.default, &row.default_label) {
                    (Some(value), _) if !value.is_null() => json(value),
                    (_, Some(label)) => format!("null  /* {} */", one_line(&label.text)),
                    _ => "null".to_string(),
                };
                out.push_str(&format!(
                    "  // {}: {},  // {}\n",
                    quote(&row.key),
                    default,
                    one_line(title)
                ));
            }
        }
    }
    out.push_str("}\n");
    out
}

fn quote(text: &str) -> String {
    Value::String(text.to_string()).to_string()
}

fn json(value: &Value) -> String {
    value.to_string()
}

/// `text` on one line, safe inside a `//` comment.
fn one_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ").replace("*/", "* /")
}
