//! A small JSON reader for Chromium's JSON trace (`traceEvents`), so the exporter needs nothing
//! but std. A value keeps the text it was parsed from, so a number keeps every digit (a 64-bit id
//! or a microsecond timestamp with a fraction converts exactly) and a nested argument goes out
//! as the JSON it came in as.

/// Why the bytes are not JSON this reader takes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JsonError {
    /// Byte offset of the problem.
    pub offset: usize,
    pub what: &'static str,
}

impl std::fmt::Display for JsonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "invalid JSON at byte {}: {}", self.offset, self.what)
    }
}

impl std::error::Error for JsonError {}

/// Arrays and objects nest at most this deep: deeper input is an error, never a stack overflow.
const MAX_DEPTH: usize = 128;

/// A parsed value. Strings are unescaped; numbers stay as their text.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum Value<'a> {
    Null,
    Bool(bool),
    Number(&'a str),
    String(String),
    Array(Vec<Value<'a>>, &'a str),
    Object(Vec<(String, Value<'a>)>, &'a str),
}

impl<'a> Value<'a> {
    pub(crate) fn get(&self, key: &str) -> Option<&Value<'a>> {
        match self {
            Value::Object(entries, _) => {
                entries.iter().find(|(name, _)| name == key).map(|(_, value)| value)
            }
            _ => None,
        }
    }

    pub(crate) fn as_str(&self) -> Option<&str> {
        match self {
            Value::String(text) => Some(text),
            _ => None,
        }
    }

    pub(crate) fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(value) => Some(*value),
            _ => None,
        }
    }

    /// An integer: a JSON number with no fraction or exponent, or a string of decimal digits or
    /// `0x` hex (Chromium writes ids as `"0x2a"`).
    pub(crate) fn as_u64(&self) -> Option<u64> {
        match self {
            Value::Number(text) => text.parse().ok(),
            Value::String(text) => {
                match text.strip_prefix("0x").or_else(|| text.strip_prefix("0X")) {
                    Some(hex) => u64::from_str_radix(hex, 16).ok(),
                    None => text.parse().ok(),
                }
            }
            _ => None,
        }
    }

    pub(crate) fn as_i64(&self) -> Option<i64> {
        match self {
            Value::Number(text) => text.parse().ok(),
            _ => None,
        }
    }

    pub(crate) fn as_f64(&self) -> Option<f64> {
        match self {
            Value::Number(text) => text.parse().ok(),
            _ => None,
        }
    }

    /// A microsecond number as whole nanoseconds, exactly: `12.3456` is 12345 (digits past the
    /// third decimal are cut). None for a negative, an exponent or a value past u64.
    pub(crate) fn as_micros_in_ns(&self) -> Option<u64> {
        let Value::Number(text) = self else { return None };
        let (whole, fraction) = text.split_once('.').unwrap_or((text, ""));
        if whole.starts_with('-') || text.contains(['e', 'E']) {
            return None;
        }
        let mut ns = whole.parse::<u64>().ok()?.checked_mul(1000)?;
        for (place, digit) in fraction.bytes().take(3).enumerate() {
            ns = ns.checked_add(u64::from(digit - b'0') * [100, 10, 1][place])?;
        }
        Some(ns)
    }

    pub(crate) fn as_array(&self) -> Option<&[Value<'a>]> {
        match self {
            Value::Array(items, _) => Some(items),
            _ => None,
        }
    }

    pub(crate) fn as_object(&self) -> Option<&[(String, Value<'a>)]> {
        match self {
            Value::Object(entries, _) => Some(entries),
            _ => None,
        }
    }

    /// The JSON text of an array or object as it was written.
    pub(crate) fn raw(&self) -> Option<&'a str> {
        match self {
            Value::Array(_, raw) | Value::Object(_, raw) => Some(raw),
            Value::Number(text) => Some(text),
            _ => None,
        }
    }
}

/// Parses one JSON document (surrounding white space allowed).
pub(crate) fn parse(text: &str) -> Result<Value<'_>, JsonError> {
    let mut parser = Parser { text, bytes: text.as_bytes(), at: 0 };
    let value = parser.value(0)?;
    parser.space();
    if parser.at != parser.bytes.len() {
        return Err(parser.error("text after the value"));
    }
    Ok(value)
}

struct Parser<'a> {
    text: &'a str,
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Parser<'a> {
    fn error(&self, what: &'static str) -> JsonError {
        JsonError { offset: self.at, what }
    }

    fn space(&mut self) {
        while let Some(b' ' | b'\t' | b'\n' | b'\r') = self.bytes.get(self.at) {
            self.at += 1;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.at).copied()
    }

    fn consume(&mut self, byte: u8, what: &'static str) -> Result<(), JsonError> {
        self.space();
        if self.peek() != Some(byte) {
            return Err(self.error(what));
        }
        self.at += 1;
        Ok(())
    }

    fn literal(&mut self, word: &str, value: Value<'a>) -> Result<Value<'a>, JsonError> {
        if self.bytes[self.at..].starts_with(word.as_bytes()) {
            self.at += word.len();
            Ok(value)
        } else {
            Err(self.error("unknown literal"))
        }
    }

    fn value(&mut self, depth: usize) -> Result<Value<'a>, JsonError> {
        self.space();
        match self.peek() {
            None => Err(self.error("unexpected end")),
            Some(b'n') => self.literal("null", Value::Null),
            Some(b't') => self.literal("true", Value::Bool(true)),
            Some(b'f') => self.literal("false", Value::Bool(false)),
            Some(b'"') => self.string().map(Value::String),
            Some(b'[') => self.array(depth + 1),
            Some(b'{') => self.object(depth + 1),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.error("unexpected character")),
        }
    }

    fn number(&mut self) -> Result<Value<'a>, JsonError> {
        let start = self.at;
        if self.peek() == Some(b'-') {
            self.at += 1;
        }
        let digits = |parser: &mut Parser<'a>| {
            let from = parser.at;
            while let Some(b'0'..=b'9') = parser.peek() {
                parser.at += 1;
            }
            parser.at > from
        };
        if !digits(self) {
            return Err(self.error("a number needs digits"));
        }
        if self.peek() == Some(b'.') {
            self.at += 1;
            if !digits(self) {
                return Err(self.error("a fraction needs digits"));
            }
        }
        if let Some(b'e' | b'E') = self.peek() {
            self.at += 1;
            if let Some(b'+' | b'-') = self.peek() {
                self.at += 1;
            }
            if !digits(self) {
                return Err(self.error("an exponent needs digits"));
            }
        }
        Ok(Value::Number(&self.text[start..self.at]))
    }

    fn hex4(&mut self) -> Result<u32, JsonError> {
        let digits = self.bytes.get(self.at..self.at + 4).ok_or(self.error("short \\u escape"))?;
        let text = std::str::from_utf8(digits).map_err(|_| self.error("bad \\u escape"))?;
        let value = u32::from_str_radix(text, 16).map_err(|_| self.error("bad \\u escape"))?;
        self.at += 4;
        Ok(value)
    }

    fn string(&mut self) -> Result<String, JsonError> {
        self.at += 1;
        let mut out = String::new();
        loop {
            let run = self.at;
            while let Some(byte) = self.peek() {
                if byte == b'"' || byte == b'\\' || byte < 0x20 {
                    break;
                }
                self.at += 1;
            }
            out.push_str(&self.text[run..self.at]);
            match self.peek() {
                None => return Err(self.error("unterminated string")),
                Some(b'"') => {
                    self.at += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.at += 1;
                    let escape = self.peek().ok_or(self.error("unterminated escape"))?;
                    self.at += 1;
                    match escape {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{8}'),
                        b'f' => out.push('\u{c}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => out.push(self.unicode_escape()?),
                        _ => return Err(self.error("unknown escape")),
                    }
                }
                Some(_) => return Err(self.error("control character in a string")),
            }
        }
    }

    /// The character of a `\u` escape (its `\u` read), joining a surrogate pair; a lone surrogate
    /// becomes U+FFFD, as a lossy UTF-8 read would.
    fn unicode_escape(&mut self) -> Result<char, JsonError> {
        let first = self.hex4()?;
        if (0xD800..0xDC00).contains(&first) && self.bytes[self.at..].starts_with(b"\\u") {
            let save = self.at;
            self.at += 2;
            let second = self.hex4()?;
            if (0xDC00..0xE000).contains(&second) {
                let code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
                return Ok(char::from_u32(code).unwrap_or('\u{FFFD}'));
            }
            self.at = save;
        }
        Ok(char::from_u32(first).unwrap_or('\u{FFFD}'))
    }

    fn array(&mut self, depth: usize) -> Result<Value<'a>, JsonError> {
        if depth > MAX_DEPTH {
            return Err(self.error("nested too deep"));
        }
        let start = self.at;
        self.at += 1;
        let mut items = Vec::new();
        self.space();
        if self.peek() == Some(b']') {
            self.at += 1;
            return Ok(Value::Array(items, &self.text[start..self.at]));
        }
        loop {
            items.push(self.value(depth)?);
            self.space();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b']') => {
                    self.at += 1;
                    return Ok(Value::Array(items, &self.text[start..self.at]));
                }
                _ => return Err(self.error("expected , or ]")),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Value<'a>, JsonError> {
        if depth > MAX_DEPTH {
            return Err(self.error("nested too deep"));
        }
        let start = self.at;
        self.at += 1;
        let mut entries = Vec::new();
        self.space();
        if self.peek() == Some(b'}') {
            self.at += 1;
            return Ok(Value::Object(entries, &self.text[start..self.at]));
        }
        loop {
            self.space();
            if self.peek() != Some(b'"') {
                return Err(self.error("expected a key"));
            }
            let key = self.string()?;
            self.consume(b':', "expected :")?;
            entries.push((key, self.value(depth)?));
            self.space();
            match self.peek() {
                Some(b',') => self.at += 1,
                Some(b'}') => {
                    self.at += 1;
                    return Ok(Value::Object(entries, &self.text[start..self.at]));
                }
                _ => return Err(self.error("expected , or }")),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_trace_document_parses() {
        let text = r#" {"traceEvents":[{"name":"a\"b\u00e9\ud83d\ude00","ts":12.3456,"id":"0x2A",
            "args":{"n":[1,2,{"x":null}]},"ok":true}],"meta":-1.5e3} "#;
        let value = parse(text).expect("parses");
        let event = &value.get("traceEvents").and_then(Value::as_array).expect("events")[0];
        assert_eq!(event.get("name").and_then(Value::as_str), Some("a\"b\u{e9}\u{1F600}"));
        assert_eq!(event.get("ts").and_then(Value::as_micros_in_ns), Some(12_345));
        assert_eq!(event.get("id").and_then(Value::as_u64), Some(42));
        assert_eq!(event.get("ok").and_then(Value::as_bool), Some(true));
        assert_eq!(
            event.get("args").and_then(|a| a.get("n")).and_then(Value::raw),
            Some(r#"[1,2,{"x":null}]"#)
        );
        assert_eq!(value.get("meta").and_then(Value::as_f64), Some(-1500.0));
        assert_eq!(value.get("meta").and_then(Value::as_micros_in_ns), None);
    }

    #[test]
    fn big_ids_keep_every_digit() {
        let value = parse("[18446744073709551615, \"18446744073709551615\"]").expect("parses");
        let items = value.as_array().expect("array");
        assert_eq!(items[0].as_u64(), Some(u64::MAX));
        assert_eq!(items[1].as_u64(), Some(u64::MAX));
    }

    #[test]
    fn bad_input_is_an_error_not_a_panic() {
        for text in ["", "{", "[1,]", "{\"a\" 1}", "\"\\x\"", "tru", "1.", "[1] x", "\"\\u12\""] {
            assert!(parse(text).is_err(), "{text:?} is not JSON");
        }
        let deep = "[".repeat(MAX_DEPTH + 1) + &"]".repeat(MAX_DEPTH + 1);
        assert_eq!(parse(&deep).map_err(|error| error.what), Err("nested too deep"));
        assert!(parse(&("[".repeat(MAX_DEPTH) + &"]".repeat(MAX_DEPTH))).is_ok());
    }
}
