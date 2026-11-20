//! JSON lines in the Python kit's shape (keys sorted, `ev`, `wall`, `mono`), so pace_probe.py and
//! the analyzers read both engines' logs the same way.

use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};

pub enum Value {
    Int(i64),
    Num(f64, usize),
    Str(String),
    Bool(bool),
}

pub struct Log {
    out: Option<BufWriter<File>>,
}

fn quote(text: &str, out: &mut String) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if u32::from(c) < 0x20 => out.push_str(&format!("\\u{:04x}", u32::from(c))),
            c => out.push(c),
        }
    }
    out.push('"');
}

impl Log {
    pub fn open(path: Option<&str>) -> Result<Log, String> {
        let out = match path {
            None => None,
            Some(path) => Some(BufWriter::new(
                OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
                    .map_err(|e| format!("--log {path}: {e}"))?,
            )),
        };
        Ok(Log { out })
    }

    /// One event; `wall` and `mono` are added when the fields lack them.
    pub fn event(&mut self, ev: &str, mut fields: Vec<(&str, Value)>) {
        let Some(out) = self.out.as_mut() else {
            return;
        };
        if !fields.iter().any(|(k, _)| *k == "wall") {
            fields.push(("wall", Value::Num(crate::sys::wall(), 6)));
        }
        if !fields.iter().any(|(k, _)| *k == "mono") {
            fields.push(("mono", Value::Num(crate::sys::monotonic(), 6)));
        }
        fields.push(("ev", Value::Str(ev.to_string())));
        fields.sort_by(|a, b| a.0.cmp(b.0));
        let mut line = String::from("{");
        for (i, (key, value)) in fields.iter().enumerate() {
            if i > 0 {
                line.push_str(", ");
            }
            quote(key, &mut line);
            line.push_str(": ");
            match value {
                Value::Int(n) => line.push_str(&n.to_string()),
                Value::Num(x, places) if x.is_finite() => {
                    line.push_str(&format!("{:.*}", *places, x))
                }
                Value::Num(..) => line.push_str("null"),
                Value::Str(s) => quote(s, &mut line),
                Value::Bool(b) => line.push_str(if *b { "true" } else { "false" }),
            }
        }
        line.push_str("}\n");
        let _ = out.write_all(line.as_bytes());
    }

    pub fn flush(&mut self) {
        if let Some(out) = self.out.as_mut() {
            let _ = out.flush();
        }
    }
}
