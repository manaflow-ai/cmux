//! `plans/cmux-next/action-catalog.json` as `ActionCatalogDumpTests.json` writes it from the decoded catalog:
//! the catalog JSON the app decodes, less the tables the dump leaves out (`locale`, `debug_build_only`,
//! `customize_elements`), with what the Swift types add on decoding: each binding's `when` clause parsed from
//! its `when_text` (`WhenClause` reflected by `Mirror`), and `subtitle` and `symbol` (always nil from the
//! catalog) on every `ActionEnumCase`. Printed sorted and pretty, slashes unescaped.

use serde_json::{Map, Value, json};

use crate::apple_json;

pub fn export(root: &Value) -> Result<String, String> {
    let mut root = root.clone();
    let object = root.as_object_mut().ok_or("the catalog is not an object")?;
    for key in ["locale", "debug_build_only", "customize_elements"] {
        object.remove(key);
    }
    if let Some(Value::Array(actions)) = object.get_mut("actions") {
        for action in actions {
            for argument in
                action.get_mut("arguments").and_then(Value::as_array_mut).into_iter().flatten()
            {
                let enumeration =
                    argument.pointer_mut("/kind/enumeration").and_then(Value::as_array_mut);
                enumeration.into_iter().flatten().for_each(add_case_fields);
                let pinned =
                    argument.pointer_mut("/suggestions/pinned").and_then(Value::as_array_mut);
                pinned.into_iter().flatten().for_each(add_case_fields);
            }
        }
    }
    if let Some(Value::Object(bindings)) = object.get_mut("key_binding_defaults") {
        for (name, list) in bindings.iter_mut() {
            let Value::Array(rows) = list else { continue };
            if name == "text_input_keys" {
                rows.sort_by_key(sort_key);
                continue;
            }
            let mut kept = Vec::with_capacity(rows.len());
            for mut row in rows.drain(..) {
                if let Value::Object(binding) = &mut row
                    && binding.contains_key("when_text")
                {
                    let when = match binding.get("when_text") {
                        Some(Value::String(text)) => match parse(text) {
                            Some(clause) => clause,
                            // RustActionCatalog drops a binding whose clause does not parse.
                            None => continue,
                        },
                        _ => Value::Null,
                    };
                    binding.insert("when".into(), when);
                }
                kept.push(row);
            }
            *rows = kept;
        }
    }
    Ok(apple_json::pretty(&root, false) + "\n")
}

fn add_case_fields(case: &mut Value) {
    if let Value::Object(case) = case {
        case.entry("subtitle").or_insert(Value::Null);
        case.entry("symbol").or_insert(Value::Null);
    }
}

/// `ActionCatalogDumpTests.sortKey`: the key, NUL, then the modifiers as JSON text.
fn sort_key(wire: &Value) -> String {
    let key = wire.get("key").and_then(Value::as_str).unwrap_or("");
    let modifiers: Vec<String> = wire
        .get("modifiers")
        .and_then(Value::as_array)
        .map(|m| m.iter().filter_map(Value::as_str).map(|m| format!("\"{m}\"")).collect())
        .unwrap_or_default();
    format!("{key}\u{0}[{}]", modifiers.join(","))
}

// MARK: - WhenClause (WhenClauseParser.swift), reflected as the dump's `encode` reflects the enum

/// The clause `text` parses to, as `{case: payload}`; None when it does not parse.
pub fn parse(text: &str) -> Option<Value> {
    let mut parser = Parser { bytes: text.as_bytes(), index: 0 };
    let clause = parser.or()?;
    parser.skip_space();
    parser.at_end().then_some(clause)
}

struct Parser<'a> {
    bytes: &'a [u8],
    index: usize,
}

fn word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-' | b':')
}

fn value_byte(byte: u8) -> bool {
    word_byte(byte) || matches!(byte, b'/' | b'@' | b'+' | b'#')
}

fn case(name: &str, payload: Value) -> Value {
    let mut object = Map::new();
    object.insert(name.into(), payload);
    Value::Object(object)
}

impl Parser<'_> {
    fn at_end(&self) -> bool {
        self.index >= self.bytes.len()
    }

    fn skip_space(&mut self) {
        while self.index < self.bytes.len() && matches!(self.bytes[self.index], b' ' | b'\t') {
            self.index += 1;
        }
    }

    fn take(&mut self, token: &str) -> bool {
        self.skip_space();
        if self.bytes[self.index..].starts_with(token.as_bytes()) {
            self.index += token.len();
            true
        } else {
            false
        }
    }

    fn take_word(&mut self, word: &str) -> bool {
        let start = self.index;
        if !self.take(word) {
            return false;
        }
        if self.index < self.bytes.len() && word_byte(self.bytes[self.index]) {
            self.index = start;
            return false;
        }
        true
    }

    fn or(&mut self) -> Option<Value> {
        let mut clauses = vec![self.and()?];
        while self.take("||") {
            clauses.push(self.and()?);
        }
        Some(if clauses.len() == 1 { clauses.remove(0) } else { case("or", Value::Array(clauses)) })
    }

    fn and(&mut self) -> Option<Value> {
        let mut clauses = vec![self.unary()?];
        while self.take("&&") {
            clauses.push(self.unary()?);
        }
        Some(if clauses.len() == 1 {
            clauses.remove(0)
        } else {
            case("and", Value::Array(clauses))
        })
    }

    fn unary(&mut self) -> Option<Value> {
        self.skip_space();
        if self.index + 1 < self.bytes.len()
            && self.bytes[self.index] == b'!'
            && self.bytes[self.index + 1] != b'='
        {
            self.index += 1;
            return Some(case("not", self.unary()?));
        }
        self.primary()
    }

    fn primary(&mut self) -> Option<Value> {
        if self.take("(") {
            let inner = self.or()?;
            return self.take(")").then_some(inner);
        }
        if self.take_word("true") {
            return Some(case("constant", json!(true)));
        }
        if self.take_word("false") {
            return Some(case("constant", json!(false)));
        }
        let key = self.key()?;
        if self.take("==") {
            return Some(case("equals", json!([key, self.value()?])));
        }
        if self.take("!=") {
            return Some(case("notEquals", json!([key, self.value()?])));
        }
        if self.take("=~") {
            // `matches(String, pattern: String)`: Mirror labels the unlabeled element `.0`, which the dump
            // writes as its index.
            return Some(case("matches", json!({"0": key, "pattern": self.regex()?})));
        }
        let before_not = self.index;
        if self.take_word("not") {
            if !self.take_word("in") {
                self.index = before_not;
                return Some(case("has", json!(key)));
            }
            return Some(case("not", case("isIn", json!({"0": key, "listKey": self.key()?}))));
        }
        if self.take_word("in") {
            return Some(case("isIn", json!({"0": key, "listKey": self.key()?})));
        }
        Some(case("has", json!(key)))
    }

    fn key(&mut self) -> Option<String> {
        self.skip_space();
        let start = self.index;
        while self.index < self.bytes.len() && word_byte(self.bytes[self.index]) {
            self.index += 1;
        }
        (self.index > start)
            .then(|| String::from_utf8_lossy(&self.bytes[start..self.index]).into_owned())
    }

    /// `KeyContextValue` reflected: `{"bool": b}`, `{"string": s}` or `{"number": d}`.
    fn value(&mut self) -> Option<Value> {
        self.skip_space();
        let quote = *self.bytes.get(self.index)?;
        if quote == b'\'' || quote == b'"' {
            self.index += 1;
            let start = self.index;
            while self.index < self.bytes.len() && self.bytes[self.index] != quote {
                self.index += 1;
            }
            if self.at_end() {
                return None;
            }
            let text = String::from_utf8_lossy(&self.bytes[start..self.index]).into_owned();
            self.index += 1;
            return Some(case("string", json!(text)));
        }
        let start = self.index;
        while self.index < self.bytes.len() && value_byte(self.bytes[self.index]) {
            self.index += 1;
        }
        if self.index == start {
            return None;
        }
        let text = String::from_utf8_lossy(&self.bytes[start..self.index]).into_owned();
        Some(match text.as_str() {
            "true" => case("bool", json!(true)),
            "false" => case("bool", json!(false)),
            _ => match swift_double(&text) {
                // JSONSerialization writes an integral Double without a fraction.
                Some(number) if number.fract() == 0.0 && number.abs() < 1e15 => {
                    case("number", json!(number as i64))
                }
                Some(number) => case("number", json!(number)),
                None => case("string", json!(text)),
            },
        })
    }

    fn regex(&mut self) -> Option<String> {
        self.skip_space();
        if self.bytes.get(self.index) != Some(&b'/') {
            return None;
        }
        self.index += 1;
        let mut pattern = Vec::new();
        while self.index < self.bytes.len() && self.bytes[self.index] != b'/' {
            if self.bytes[self.index] == b'\\' && self.index + 1 < self.bytes.len() {
                pattern.push(self.bytes[self.index]);
                self.index += 1;
            }
            pattern.push(self.bytes[self.index]);
            self.index += 1;
        }
        if self.at_end() {
            return None;
        }
        self.index += 1;
        let mut flags = String::new();
        while self.index < self.bytes.len() && word_byte(self.bytes[self.index]) {
            flags.push(self.bytes[self.index] as char);
            self.index += 1;
        }
        let text = String::from_utf8_lossy(&pattern).into_owned();
        Some(if flags.contains('i') { format!("(?i){text}") } else { text })
    }
}

/// Swift's `Double(text)` for the bytes a bare value can hold: a decimal with an optional sign, fraction and
/// exponent (`inf`/`nan` spellings hold no value bytes Swift would read differently from Rust's, but are
/// left as strings: no clause uses them).
fn swift_double(text: &str) -> Option<f64> {
    let digits = text.trim_start_matches(['+', '-']);
    if !digits.starts_with(|c: char| c.is_ascii_digit() || c == '.') {
        return None;
    }
    text.parse::<f64>().ok().filter(|n| n.is_finite())
}
