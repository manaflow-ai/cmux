//! The panic log written with std alone.
//!
//! The same line format as the serde_json writer (see the crate docs), for a
//! process that stays std and libc: the holder holds every PTY of an install
//! and keeps its dependency graph to what it audits (its Cargo.toml). JSON
//! strings are escaped by hand to RFC 8259 section 7, which is all a line
//! needs: every value is text, a whole number or a bool.

use std::path::PathBuf;

/// The keys the panic itself writes. A field with one of these keys is left
/// out, as the serde_json writer lets the panic's own key win.
const PANIC_KEYS: [&str; 6] = ["message", "location", "thread", "at_ms", "test", "backtrace"];

/// One field value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    /// A JSON string.
    Text(String),
    /// A JSON whole number.
    Number(u64),
    /// A JSON bool.
    Bool(bool),
}

impl From<&str> for Value {
    fn from(text: &str) -> Self {
        Self::Text(text.to_string())
    }
}

impl From<String> for Value {
    fn from(text: String) -> Self {
        Self::Text(text)
    }
}

impl From<u64> for Value {
    fn from(number: u64) -> Self {
        Self::Number(number)
    }
}

impl From<u32> for Value {
    fn from(number: u32) -> Self {
        Self::Number(u64::from(number))
    }
}

impl From<bool> for Value {
    fn from(flag: bool) -> Self {
        Self::Bool(flag)
    }
}

/// Fields every line carries besides the panic itself, in insertion order.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Fields(Vec<(String, Value)>);

impl Fields {
    /// No fields.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set `key` to `value`, replacing an earlier value of `key`.
    pub fn insert(&mut self, key: impl Into<String>, value: impl Into<Value>) {
        let (key, value) = (key.into(), value.into());
        match self.0.iter_mut().find(|(existing, _)| *existing == key) {
            Some(slot) => slot.1 = value,
            None => self.0.push((key, value)),
        }
    }
}

/// Install a hook that appends each panic to `path`, then runs the previous
/// hook. `is_test_thread` marks lines from a debug test trigger (`"test": true`).
pub fn install(path: PathBuf, fields: Fields, is_test_thread: fn(&str) -> bool) {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let panic = crate::Panic::capture(info, is_test_thread);
        let mut line = record(
            &fields,
            &panic.message,
            &panic.location,
            &panic.thread,
            panic.test,
            panic.backtrace,
        );
        line.push('\n');
        crate::append_line(&|| crate::open_append(&path), line.as_bytes());
        previous(info);
    }));
}

/// One log line's JSON object, without the newline: `fields`, then the
/// panic's own keys.
pub fn record(
    fields: &Fields,
    message: &str,
    location: &str,
    thread: &str,
    test: bool,
    mut backtrace: String,
) -> String {
    crate::truncate_backtrace(&mut backtrace);
    let mut line = String::with_capacity(256 + message.len() + backtrace.len());
    line.push('{');
    for (key, value) in fields.0.iter().filter(|(key, _)| !PANIC_KEYS.contains(&key.as_str())) {
        push_key(&mut line, key);
        match value {
            Value::Text(text) => push_string(&mut line, text),
            Value::Number(number) => line.push_str(&number.to_string()),
            Value::Bool(flag) => line.push_str(if *flag { "true" } else { "false" }),
        }
    }
    for (key, text) in [("message", message), ("location", location), ("thread", thread)] {
        push_key(&mut line, key);
        push_string(&mut line, text);
    }
    push_key(&mut line, "at_ms");
    line.push_str(&crate::now_ms().to_string());
    push_key(&mut line, "test");
    line.push_str(if test { "true" } else { "false" });
    push_key(&mut line, "backtrace");
    push_string(&mut line, &backtrace);
    line.push('}');
    line
}

/// `"key":`, after a comma unless it is the object's first member.
fn push_key(line: &mut String, key: &str) {
    if !line.ends_with('{') {
        line.push(',');
    }
    push_string(line, key);
    line.push(':');
}

/// `text` as a JSON string: quotes, backslash and every control character
/// below U+0020 escaped (RFC 8259 section 7); everything else as is.
pub fn push_string(out: &mut String, text: &str) {
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0c}' => out.push_str("\\f"),
            c if u32::from(c) < 0x20 => {
                const HEX: &[u8; 16] = b"0123456789abcdef";
                let code = u32::from(c) as usize;
                out.push_str("\\u00");
                out.push(char::from(HEX[code >> 4]));
                out.push(char::from(HEX[code & 0xf]));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(line: &str) -> serde_json::Value {
        serde_json::from_str(line).unwrap_or_else(|error| panic!("{error}: {line}"))
    }

    #[test]
    fn every_string_round_trips_through_a_json_parser() {
        let mut every_control: String = (0u8..0x20).map(char::from).collect();
        every_control.push_str("\u{7f}\"\\/é\u{2028}\u{2029}\u{1f600}");
        for text in ["", "plain", "quote \" and \\ back", "line\nbreak\r\ttab", &every_control] {
            let mut out = String::new();
            push_string(&mut out, text);
            assert_eq!(parse(&out), serde_json::Value::String(text.to_string()), "{out}");
        }
    }

    #[cfg(feature = "json")]
    #[test]
    fn a_line_matches_the_serde_json_writer_and_the_panic_keys_win() {
        let mut fields = Fields::new();
        fields.insert("process", "cmux-holder");
        fields.insert("holder_pid", 42_u32);
        fields.insert("debug", true);
        fields.insert("message", "a field must not shadow the panic");
        fields.insert("process", "cmux-holder\n");
        let backtrace = "é".repeat(crate::MAX_BACKTRACE_BYTES);
        let mut line =
            parse(&record(&fields, "m \"q\"", "src/a.rs:1:2", "worker", false, backtrace.clone()));

        let mut json_fields = crate::Fields::new();
        json_fields.insert("process".into(), "cmux-holder\n".into());
        json_fields.insert("holder_pid".into(), 42.into());
        json_fields.insert("debug".into(), true.into());
        let mut expected =
            crate::record(&json_fields, "m \"q\"", "src/a.rs:1:2", "worker", false, backtrace);
        assert!(line["at_ms"].as_u64().is_some_and(|at| at > 0));
        line["at_ms"] = 0.into();
        expected["at_ms"] = 0.into();
        assert_eq!(line, expected);
        assert!(line["backtrace"].as_str().unwrap().len() <= crate::MAX_BACKTRACE_BYTES);
    }
}
