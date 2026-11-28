//! Swift `ConfigFieldReader`: reads typed fields of one cmux.json object and records a diagnostic for every
//! bad value, which keeps its default. Ranges and defaults come from the embedded settings schema.

use serde_json::{Map, Value, json};

use crate::schema::{Kind, Schema};

pub(crate) fn invalid(path: impl Into<String>, message: impl Into<String>) -> Value {
    json!({"kind": "invalid_value", "path": path.into(), "message": message.into()})
}

/// A Swift `Double` printed with `\(x)`: whole numbers keep one decimal.
pub(crate) fn swift_double(x: f64) -> String {
    if x.fract() == 0.0 && x.abs() < 1e16 { format!("{x:.1}") } else { format!("{x}") }
}

/// The value at key path `path` of objects.
pub(crate) fn value_at<'a>(root: &'a Value, path: &[&str]) -> Option<&'a Value> {
    path.iter().try_fold(root, |value, key| value.as_object()?.get(*key))
}

/// The schema default of dotted key `key` (`null` when the row has none).
pub(crate) fn default_of(key: &str) -> Value {
    Schema::embedded().row(key).and_then(|row| row.default.clone()).unwrap_or(Value::Null)
}

pub(crate) fn range_of(key: &str) -> (f64, f64) {
    match Schema::embedded().row(key).map(|row| &row.kind) {
        Some(Kind::Number(range)) | Some(Kind::ChoiceOrNumber(_, range)) => (range.min, range.max),
        _ => (f64::MIN, f64::MAX),
    }
}

/// The defaults of `prefix.KEY` for each key, by key (colors and unset keys are `null`).
pub(crate) fn defaults(prefix: &str, keys: &[&str]) -> Value {
    let mut map = Map::new();
    for key in keys {
        map.insert((*key).into(), default_of(&format!("{prefix}.{key}")));
    }
    Value::Object(map)
}

/// `#RRGGBB`, `#RGB` or `#RRGGBBAA` (`#` optional, spaces around trimmed): Swift `ThemeRGB(cssHex:)`.
pub(crate) fn css_hex(text: &str) -> Option<Value> {
    let trimmed = text.trim_matches(|c: char| c == ' ' || c == '\t');
    let digits = trimmed.strip_prefix('#').unwrap_or(trimmed);
    if ![3, 6, 8].contains(&digits.chars().count())
        || !digits.chars().all(|c| c.is_ascii_hexdigit())
    {
        return None;
    }
    let mut value = u64::from_str_radix(digits, 16).ok()?;
    if digits.len() == 3 {
        let (r, g, b) = ((value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF);
        value = ((r * 17) << 16) | ((g * 17) << 8) | (b * 17);
    }
    let mut alpha = 1.0;
    if digits.len() == 8 {
        alpha = (value & 0xFF) as f64 / 255.0;
        value >>= 8;
    }
    let channel = |shift: u32| f64::from(((value >> shift) & 0xFF) as u8) / 255.0;
    Some(json!({"red": channel(16), "green": channel(8), "blue": channel(0), "alpha": alpha}))
}

pub(crate) struct Reader {
    pub(crate) members: Map<String, Value>,
    path: String,
    pub(crate) values: Map<String, Value>,
    pub(crate) diagnostics: Vec<Value>,
}

impl Reader {
    /// The object at dotted `path`, or `None` (with a diagnostic in `direct` when it is not an object).
    pub(crate) fn open(root: &Value, path: &str, direct: &mut Vec<Value>) -> Option<Reader> {
        let keys: Vec<&str> = path.split('.').collect();
        let value = value_at(root, &keys)?;
        let Some(members) = value.as_object() else {
            direct.push(invalid(path, "expected an object"));
            return None;
        };
        Some(Reader {
            members: members.clone(),
            path: path.into(),
            values: Map::new(),
            diagnostics: vec![],
        })
    }

    fn fail(&mut self, key: &str, message: &str) {
        self.diagnostics.push(invalid(format!("{}.{key}", self.path), message));
    }

    pub(crate) fn bool(&mut self, key: &str) {
        let Some(value) = self.members.get(key) else { return };
        if value.is_boolean() {
            self.values.insert(key.into(), value.clone());
        } else {
            self.fail(key, "expected true or false");
        }
    }

    fn number_in(&mut self, key: &str, lo: f64, hi: f64) -> Option<f64> {
        let value = self.members.get(key)?;
        let Some(number) = value.as_f64().filter(|n| n.is_finite()) else {
            self.fail(key, "expected a number");
            return None;
        };
        if number < lo || number > hi {
            self.fail(key, &format!("clamped to {}...{}", swift_double(lo), swift_double(hi)));
        }
        Some(number.max(lo).min(hi))
    }

    /// A number clamped into the schema row's range.
    pub(crate) fn number(&mut self, key: &str) {
        let (lo, hi) = range_of(&format!("{}.{key}", self.path));
        if let Some(n) = self.number_in(key, lo, hi) {
            self.values.insert(key.into(), json!(n));
        }
    }

    /// A number clamped into the schema range, then rounded (Swift `Int(value.rounded())`).
    pub(crate) fn rounded(&mut self, key: &str) {
        let (lo, hi) = range_of(&format!("{}.{key}", self.path));
        if let Some(n) = self.number_in(key, lo, hi) {
            self.values.insert(key.into(), json!(n.round() as i64));
        }
    }

    /// A number clamped into `lo...hi` (a range the schema has no row for).
    pub(crate) fn points(&mut self, key: &str, lo: f64, hi: f64) {
        if let Some(n) = self.number_in(key, lo, hi) {
            self.values.insert(key.into(), json!(n));
        }
    }

    /// One of `allowed` (in Swift's `allCases` order, which the message lists); true when set.
    pub(crate) fn choice(&mut self, key: &str, allowed: &[&str]) -> bool {
        let Some(value) = self.members.get(key) else { return false };
        match value.as_str().filter(|text| allowed.contains(text)) {
            Some(_) => {
                self.values.insert(key.into(), value.clone());
                true
            }
            None => {
                let list =
                    allowed.iter().map(|c| format!("\"{c}\"")).collect::<Vec<_>>().join(", ");
                self.fail(key, &format!("expected one of {list}"));
                false
            }
        }
    }

    /// A color: `null` or `"theme"` is the theme default (value `null`).
    pub(crate) fn color(&mut self, key: &str) {
        let Some(value) = self.members.get(key) else { return };
        let parsed = match value {
            Value::Null => Some(Value::Null),
            Value::String(text) if text == "theme" => Some(Value::Null),
            Value::String(text) => css_hex(text),
            _ => None,
        };
        match parsed {
            Some(color) => {
                self.values.insert(key.into(), color);
            }
            None => self.fail(key, "expected a #RRGGBB color"),
        }
    }
}

/// The values the schema row `key` offers, in the row's order (the order Swift's `allCases` and
/// `values` lists use, which an `expected one of` message prints).
pub(crate) fn choices_of(key: &str) -> Vec<String> {
    let Some(row) = Schema::embedded().row(key) else { return vec![] };
    row.raw()
        .get("choices")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter().filter_map(|c| c.get("value")?.as_str().map(String::from)).collect()
        })
        .unwrap_or_default()
}

/// `"a", "b", "c"`: how a message lists names.
pub(crate) fn quoted(names: &[String]) -> String {
    names.iter().map(|n| format!("\"{n}\"")).collect::<Vec<_>>().join(", ")
}
