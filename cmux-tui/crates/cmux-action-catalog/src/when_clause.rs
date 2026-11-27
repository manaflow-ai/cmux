//! `when` clauses (plans/cmux-next/keybindings.md section 4, spec K4): parsing the text of
//! keybindings.json into a tree and printing a tree back as that text. The app evaluates the
//! tree itself (`WhenClause.evaluate`, the key router's hot path); it asks here only when it
//! reads or writes the text, through [`crate::ffi`] (`when_parse`, `when_text`).
//!
//! The grammar: `!`, `&&`, `||`, `==`, `!=`, `=~`, `in`, `not in`, parentheses, `true`, `false`,
//! context keys and values (quoted, bare or numeric; `=~` takes `/regex/` with an optional `i`
//! flag). `&&` binds tighter than `||`. A parse error disables only the entry that holds it.
//!
//! The tree as JSON, one key per node: `{"const":true}`, `{"has":"k"}`, `{"not":node}`,
//! `{"and":[node…]}`, `{"or":[node…]}`, `{"eq":["k",value]}`, `{"ne":["k",value]}`,
//! `{"match":["k","pattern"]}`, `{"in":["k","listKey"]}`. A value is `{"bool":b}`,
//! `{"number":n}` (a string `"inf"`, `"-inf"` or `"nan"` when not finite), `{"string":s}` or
//! `{"strings":[s…]}`.

use serde_json::{Value, json};

/// A context value a clause compares with.
#[derive(Clone, Debug, PartialEq)]
pub enum ContextValue {
    Bool(bool),
    Number(f64),
    String(String),
    Strings(Vec<String>),
}

/// A parsed `when` clause.
#[derive(Clone, Debug, PartialEq)]
pub enum WhenClause {
    Constant(bool),
    Has(String),
    Not(Box<WhenClause>),
    And(Vec<WhenClause>),
    Or(Vec<WhenClause>),
    Equals(String, ContextValue),
    NotEquals(String, ContextValue),
    /// The key's text matches `pattern` (an `i` flag is a `(?i)` prefix).
    Matches(String, String),
    /// The key's text is one of the list `listKey` holds.
    IsIn(String, String),
}

/// What is wrong with a clause's text (English) and its UTF-8 offset.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    pub message: &'static str,
    pub offset: usize,
}

/// Parses `text`.
pub fn parse(text: &str) -> Result<WhenClause, ParseError> {
    let mut parser = Parser { bytes: text.as_bytes(), index: 0 };
    let clause = parser.parse_or()?;
    parser.skip_space();
    if parser.index < parser.bytes.len() {
        return Err(parser.error("unexpected text"));
    }
    Ok(clause)
}

/// Context key bytes: letters, digits, `.`, `_`, `-`, `:`.
pub fn is_word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':')
}

/// Bare value bytes: key bytes plus `/`, `@`, `+`, `#`.
pub fn is_value_byte(byte: u8) -> bool {
    is_word_byte(byte) || matches!(byte, b'/' | b'@' | b'+' | b'#')
}

struct Parser<'a> {
    bytes: &'a [u8],
    index: usize,
}

impl Parser<'_> {
    fn error(&self, message: &'static str) -> ParseError {
        ParseError { message, offset: self.index }
    }

    /// The byte at the cursor; nil at the end.
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.index).copied()
    }

    /// Moves past bytes while `keep` holds.
    fn skip_while(&mut self, keep: impl Fn(u8) -> bool) {
        while self.peek().is_some_and(&keep) {
            self.index += 1;
        }
    }

    fn skip_space(&mut self) {
        self.skip_while(|byte| matches!(byte, b' ' | b'\t'));
    }

    fn take(&mut self, token: &str) -> bool {
        self.skip_space();
        if self.bytes.get(self.index..).is_some_and(|rest| rest.starts_with(token.as_bytes())) {
            self.index += token.len();
            true
        } else {
            false
        }
    }

    /// A keyword followed by a non-word byte (`in` must not eat `inbox`).
    fn take_word(&mut self, word: &str) -> bool {
        let start = self.index;
        if !self.take(word) {
            return false;
        }
        if self.bytes.get(self.index).is_some_and(|byte| is_word_byte(*byte)) {
            self.index = start;
            return false;
        }
        true
    }

    fn text(&self, start: usize, end: usize) -> String {
        String::from_utf8_lossy(self.bytes.get(start..end).unwrap_or_default()).into_owned()
    }

    fn parse_or(&mut self) -> Result<WhenClause, ParseError> {
        let mut clauses = vec![self.parse_and()?];
        while self.take("||") {
            clauses.push(self.parse_and()?);
        }
        Ok(if clauses.len() == 1 { clauses.remove(0) } else { WhenClause::Or(clauses) })
    }

    fn parse_and(&mut self) -> Result<WhenClause, ParseError> {
        let mut clauses = vec![self.parse_unary()?];
        while self.take("&&") {
            clauses.push(self.parse_unary()?);
        }
        Ok(if clauses.len() == 1 { clauses.remove(0) } else { WhenClause::And(clauses) })
    }

    fn parse_unary(&mut self) -> Result<WhenClause, ParseError> {
        self.skip_space();
        if let Some([b'!', next, ..]) = self.bytes.get(self.index..)
            && *next != b'='
        {
            self.index += 1;
            return Ok(WhenClause::Not(Box::new(self.parse_unary()?)));
        }
        self.parse_primary()
    }

    fn parse_primary(&mut self) -> Result<WhenClause, ParseError> {
        if self.take("(") {
            let inner = self.parse_or()?;
            if !self.take(")") {
                return Err(self.error("expected )"));
            }
            return Ok(inner);
        }
        if self.take_word("true") {
            return Ok(WhenClause::Constant(true));
        }
        if self.take_word("false") {
            return Ok(WhenClause::Constant(false));
        }
        let key = self.parse_key()?;
        if self.take("==") {
            return Ok(WhenClause::Equals(key, self.parse_value()?));
        }
        if self.take("!=") {
            return Ok(WhenClause::NotEquals(key, self.parse_value()?));
        }
        if self.take("=~") {
            return Ok(WhenClause::Matches(key, self.parse_regex()?));
        }
        let before_not = self.index;
        if self.take_word("not") {
            if !self.take_word("in") {
                self.index = before_not;
                return Ok(WhenClause::Has(key));
            }
            return Ok(WhenClause::Not(Box::new(WhenClause::IsIn(key, self.parse_key()?))));
        }
        if self.take_word("in") {
            return Ok(WhenClause::IsIn(key, self.parse_key()?));
        }
        Ok(WhenClause::Has(key))
    }

    fn parse_key(&mut self) -> Result<String, ParseError> {
        self.skip_space();
        let start = self.index;
        self.skip_while(is_word_byte);
        if self.index == start {
            return Err(self.error("expected a context key"));
        }
        Ok(self.text(start, self.index))
    }

    fn parse_value(&mut self) -> Result<ContextValue, ParseError> {
        self.skip_space();
        let Some(&quote) = self.bytes.get(self.index) else {
            return Err(self.error("expected a value"));
        };
        if quote == b'\'' || quote == b'"' {
            self.index += 1;
            let start = self.index;
            self.skip_while(|byte| byte != quote);
            if self.peek().is_none() {
                return Err(self.error("unterminated string"));
            }
            let text = self.text(start, self.index);
            self.index += 1;
            return Ok(ContextValue::String(text));
        }
        let start = self.index;
        self.skip_while(is_value_byte);
        if self.index == start {
            return Err(self.error("expected a value"));
        }
        let text = self.text(start, self.index);
        Ok(match text.as_str() {
            "true" => ContextValue::Bool(true),
            "false" => ContextValue::Bool(false),
            _ => match parse_double(&text) {
                Some(number) => ContextValue::Number(number),
                None => ContextValue::String(text),
            },
        })
    }

    fn parse_regex(&mut self) -> Result<String, ParseError> {
        self.skip_space();
        if self.bytes.get(self.index) != Some(&b'/') {
            return Err(self.error("expected /regex/"));
        }
        self.index += 1;
        let mut pattern = Vec::new();
        loop {
            match self.bytes.get(self.index..).unwrap_or_default() {
                [] => return Err(self.error("unterminated /regex/")),
                [b'/', ..] => break,
                // An escape keeps its next byte, a `/` included.
                [b'\\', escaped, ..] => {
                    pattern.extend_from_slice(&[b'\\', *escaped]);
                    self.index += 2;
                }
                [byte, ..] => {
                    pattern.push(*byte);
                    self.index += 1;
                }
            }
        }
        self.index += 1;
        let flags_start = self.index;
        self.skip_while(is_word_byte);
        let has_i =
            self.bytes.get(flags_start..self.index).is_some_and(|flags| flags.contains(&b'i'));
        let text = String::from_utf8_lossy(&pattern).into_owned();
        Ok(if has_i { format!("(?i){text}") } else { text })
    }
}

/// `text` as a number, as Swift's `Double(text)` reads it: decimal with an optional sign and
/// exponent, `inf`/`infinity`/`nan` in any case, or a hexadecimal float (`0x1p3`, `0x1A`).
pub fn parse_double(text: &str) -> Option<f64> {
    let (negative, body) = match text.strip_prefix('-') {
        Some(body) => (true, body),
        None => (false, text.strip_prefix('+').unwrap_or(text)),
    };
    let hex = body.strip_prefix("0x").or_else(|| body.strip_prefix("0X")).filter(|h| !h.is_empty());
    let magnitude = if let Some(hex) = hex {
        parse_hex(hex)?
    } else {
        // Rust takes no second sign and no hex; it reads the rest as Swift does.
        if body.starts_with(['+', '-']) {
            return None;
        }
        body.parse::<f64>().ok()?
    };
    Some(if negative { -magnitude } else { magnitude })
}

/// A hexadecimal float's digits after `0x`: `h[.h][p[+-]d]`.
fn parse_hex(text: &str) -> Option<f64> {
    let (mantissa, exponent) = match text.split_once(['p', 'P']) {
        Some((mantissa, exponent)) => (mantissa, Some(exponent)),
        None => (text, None),
    };
    let (whole, fraction) = mantissa.split_once('.').unwrap_or((mantissa, ""));
    if whole.is_empty() && fraction.is_empty() {
        return None;
    }
    let mut value = 0f64;
    for digit in whole.chars() {
        value = value * 16.0 + f64::from(digit.to_digit(16)?);
    }
    let mut scale = 1.0 / 16.0;
    for digit in fraction.chars() {
        value += f64::from(digit.to_digit(16)?) * scale;
        scale /= 16.0;
    }
    if let Some(exponent) = exponent {
        let digits = exponent.strip_prefix(['+', '-']).unwrap_or(exponent);
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let power: i32 =
            exponent.parse().unwrap_or(if exponent.starts_with('-') { i32::MIN } else { i32::MAX });
        value *= 2f64.powi(power);
    }
    Some(value)
}

/// `clause` as keybindings.json text: parsing it gives the clause back.
pub fn text(clause: &WhenClause) -> String {
    match clause {
        WhenClause::Constant(value) => value.to_string(),
        WhenClause::Has(key) => key.clone(),
        WhenClause::Not(inner) => match inner.as_ref() {
            WhenClause::IsIn(key, list) => format!("{key} not in {list}"),
            inner => format!("!{}", operand(inner)),
        },
        WhenClause::And(clauses) => clauses
            .iter()
            .map(|clause| match clause {
                WhenClause::Or(_) => format!("({})", text(clause)),
                _ => text(clause),
            })
            .collect::<Vec<_>>()
            .join(" && "),
        WhenClause::Or(clauses) => clauses.iter().map(text).collect::<Vec<_>>().join(" || "),
        WhenClause::Equals(key, value) => format!("{key} == {}", value_text(value)),
        WhenClause::NotEquals(key, value) => format!("{key} != {}", value_text(value)),
        WhenClause::Matches(key, pattern) => match pattern.strip_prefix("(?i)") {
            Some(body) => format!("{key} =~ /{body}/i"),
            None => format!("{key} =~ /{pattern}/"),
        },
        WhenClause::IsIn(key, list) => format!("{key} in {list}"),
    }
}

/// The clause as the operand of `!`.
fn operand(clause: &WhenClause) -> String {
    match clause {
        WhenClause::Constant(_) | WhenClause::Has(_) => text(clause),
        WhenClause::Not(inner) if !matches!(inner.as_ref(), WhenClause::IsIn(..)) => text(clause),
        _ => format!("({})", text(clause)),
    }
}

fn value_text(value: &ContextValue) -> String {
    match value {
        ContextValue::Bool(flag) => flag.to_string(),
        ContextValue::Number(number) => {
            if number.round() == *number && number.abs() < 1e15 {
                format!("{}", *number as i64)
            } else {
                swift_double(*number)
            }
        }
        ContextValue::Strings(list) => quoted(&list.join(",")),
        ContextValue::String(text) => {
            let bare = !text.is_empty()
                && text.bytes().all(is_value_byte)
                && text != "true"
                && text != "false"
                && parse_double(text).is_none();
            if bare { text.clone() } else { quoted(text) }
        }
    }
}

fn quoted(text: &str) -> String {
    if text.contains('\'') { format!("\"{text}\"") } else { format!("'{text}'") }
}

/// Swift's `String(Double)`: the shortest digits that read back, in decimal notation (with a
/// `.0` when whole) from 1e-4 up to 2^54, else exponential (`1e-05`, `1.5e+20`).
pub fn swift_double(number: f64) -> String {
    if number.is_nan() {
        return "nan".into();
    }
    if number.is_infinite() {
        return if number < 0.0 { "-inf".into() } else { "inf".into() };
    }
    let magnitude = number.abs();
    if magnitude == 0.0 || (1e-4..=18014398509481984.0).contains(&magnitude) {
        let text = format!("{number}");
        return if text.contains('.') { text } else { format!("{text}.0") };
    }
    let exponential = format!("{number:e}");
    let (digits, exponent) = exponential.split_once('e').unwrap_or((&exponential, "0"));
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let sign = if exponent < 0 { '-' } else { '+' };
    format!("{digits}e{sign}{:02}", exponent.abs())
}

// MARK: - JSON

/// The tree as JSON (the module doc's shape).
pub fn to_json(clause: &WhenClause) -> Value {
    match clause {
        WhenClause::Constant(value) => json!({ "const": value }),
        WhenClause::Has(key) => json!({ "has": key }),
        WhenClause::Not(inner) => json!({ "not": to_json(inner) }),
        WhenClause::And(clauses) => {
            json!({ "and": clauses.iter().map(to_json).collect::<Vec<_>>() })
        }
        WhenClause::Or(clauses) => json!({ "or": clauses.iter().map(to_json).collect::<Vec<_>>() }),
        WhenClause::Equals(key, value) => json!({ "eq": [key, value_json(value)] }),
        WhenClause::NotEquals(key, value) => json!({ "ne": [key, value_json(value)] }),
        WhenClause::Matches(key, pattern) => json!({ "match": [key, pattern] }),
        WhenClause::IsIn(key, list) => json!({ "in": [key, list] }),
    }
}

fn value_json(value: &ContextValue) -> Value {
    match value {
        ContextValue::Bool(flag) => json!({ "bool": flag }),
        ContextValue::Number(number) if number.is_finite() => json!({ "number": number }),
        ContextValue::Number(number) => json!({ "number": swift_double(*number) }),
        ContextValue::String(text) => json!({ "string": text }),
        ContextValue::Strings(list) => json!({ "strings": list }),
    }
}

/// The tree a JSON node holds, nil when it is not one.
pub fn from_json(node: &Value) -> Option<WhenClause> {
    let (tag, body) = node.as_object()?.iter().next()?;
    let pair = || -> Option<(String, &Value)> {
        let items = body.as_array()?;
        Some((items.first()?.as_str()?.to_owned(), items.get(1)?))
    };
    let list = || -> Option<Vec<WhenClause>> { body.as_array()?.iter().map(from_json).collect() };
    Some(match tag.as_str() {
        "const" => WhenClause::Constant(body.as_bool()?),
        "has" => WhenClause::Has(body.as_str()?.to_owned()),
        "not" => WhenClause::Not(Box::new(from_json(body)?)),
        "and" => WhenClause::And(list()?),
        "or" => WhenClause::Or(list()?),
        "eq" => {
            let (key, value) = pair()?;
            WhenClause::Equals(key, value_from_json(value)?)
        }
        "ne" => {
            let (key, value) = pair()?;
            WhenClause::NotEquals(key, value_from_json(value)?)
        }
        "match" => {
            let (key, pattern) = pair()?;
            WhenClause::Matches(key, pattern.as_str()?.to_owned())
        }
        "in" => {
            let (key, list) = pair()?;
            WhenClause::IsIn(key, list.as_str()?.to_owned())
        }
        _ => return None,
    })
}

fn value_from_json(value: &Value) -> Option<ContextValue> {
    let (tag, body) = value.as_object()?.iter().next()?;
    Some(match tag.as_str() {
        "bool" => ContextValue::Bool(body.as_bool()?),
        "number" => match body {
            Value::String(text) => ContextValue::Number(parse_double(text)?),
            _ => ContextValue::Number(body.as_f64()?),
        },
        "string" => ContextValue::String(body.as_str()?.to_owned()),
        "strings" => ContextValue::Strings(
            body.as_array()?
                .iter()
                .map(|item| item.as_str().map(str::to_owned))
                .collect::<Option<_>>()?,
        ),
        _ => return None,
    })
}

/// The reply to `when_parse`: `{"clause":tree}` or `{"error":{"message","offset"}}`.
pub fn parse_reply(text: &str) -> Value {
    match parse(text) {
        Ok(clause) => json!({ "clause": to_json(&clause) }),
        Err(error) => json!({ "error": { "message": error.message, "offset": error.offset } }),
    }
}

/// The reply to `when_text`: `{"text":…}`, or `{"error":…}` for a node that is not a tree.
pub fn text_reply(node: &Value) -> Value {
    match from_json(node) {
        Some(clause) => json!({ "text": text(&clause) }),
        None => json!({ "error": "not a when clause tree" }),
    }
}
