//! Dynamic values: literals, `{"@path"}` bindings (JSON Pointer, relative
//! inside templates) and `{"@call"}` functions from a fixed allowlist. A
//! function outside the allowlist evaluates to null (drawn as empty text);
//! nothing here can reach the network, the disk or a command.

use crate::{caps, pointer, text};
use serde_json::{Map, Number, Value};

/// The functions a surface may call. `openUrl` is not here: it only exists as
/// a link action, which needs confirmation.
pub const ALLOWED: &[&str] = &[
    "formatString",
    "formatNumber",
    "formatCurrency",
    "pluralize",
    "required",
    "email",
    "length",
    "regex",
    "numeric",
    "and",
    "or",
    "not",
    "@index",
];

const MAX_DEPTH: usize = 16;

#[derive(Clone, Copy, Debug)]
pub struct Ctx<'a> {
    pub model: &'a Value,
    /// Absolute pointer relative paths resolve against ("" at the root).
    pub scope: &'a str,
    /// The template item index, for `@index`.
    pub index: Option<usize>,
}

impl<'a> Ctx<'a> {
    pub fn root(model: &'a Value) -> Self {
        Self { model, scope: "", index: None }
    }
}

/// The data-model path a value is bound to, if it is `{"@path": ...}`.
pub fn bound_path(v: &Value, scope: &str) -> Option<String> {
    let p = v.as_object()?.get("@path")?.as_str()?;
    Some(pointer::absolute(scope, p))
}

pub fn eval(v: &Value, ctx: Ctx<'_>) -> Value {
    eval_at(v, ctx, 0)
}

fn eval_at(v: &Value, ctx: Ctx<'_>, depth: usize) -> Value {
    if depth > MAX_DEPTH {
        return Value::Null;
    }
    match v {
        Value::Object(m) => {
            if let Some(p) = m.get("@path").and_then(Value::as_str) {
                return pointer::get(ctx.model, &pointer::absolute(ctx.scope, p))
                    .cloned()
                    .unwrap_or(Value::Null);
            }
            if let Some(name) = m.get("@call").and_then(Value::as_str) {
                let mut args = Map::new();
                if let Some(Value::Object(raw)) = m.get("args") {
                    for (k, a) in raw {
                        args.insert(k.clone(), eval_at(a, ctx, depth + 1));
                    }
                }
                return call(name, &args, ctx, depth + 1);
            }
            Value::Object(
                m.iter()
                    .map(|(k, x)| {
                        (
                            k.strip_prefix('@')
                                .filter(|r| r.starts_with('@'))
                                .unwrap_or(k)
                                .to_string(),
                            eval_at(x, ctx, depth + 1),
                        )
                    })
                    .collect(),
            )
        }
        Value::Array(items) => {
            Value::Array(items.iter().map(|x| eval_at(x, ctx, depth + 1)).collect())
        }
        other => other.clone(),
    }
}

/// Evaluate as text (null is empty).
pub fn eval_text(v: &Value, ctx: Ctx<'_>) -> String {
    text::display(&eval(v, ctx))
}

fn arg_f64(args: &Map<String, Value>, key: &str) -> Option<f64> {
    match args.get(key)? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn truthy(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        // A ValidationResult-shaped object.
        Value::Object(m) => m.get("valid").and_then(Value::as_bool).unwrap_or(false),
        _ => false,
    }
}

pub fn call(name: &str, args: &Map<String, Value>, ctx: Ctx<'_>, depth: usize) -> Value {
    let value = args.get("value").cloned().unwrap_or(Value::Null);
    match name {
        "@index" => ctx.index.map(|i| Value::from(i as u64)).unwrap_or(Value::Null),
        "formatString" => match &value {
            Value::String(s) => Value::String(interpolate(s, ctx, depth)),
            other => Value::String(text::display(other)),
        },
        "formatNumber" => match arg_f64(args, "value") {
            Some(n) => Value::String(format_number(
                n,
                arg_f64(args, "decimals").map(|d| d.clamp(0.0, 10.0) as usize),
                args.get("grouping").and_then(Value::as_bool).unwrap_or(true),
            )),
            None => Value::Null,
        },
        "formatCurrency" => {
            match (arg_f64(args, "value"), args.get("currency").and_then(Value::as_str)) {
                (Some(n), Some(code)) => {
                    let body = format_number(
                        n.abs(),
                        Some(
                            arg_f64(args, "decimals")
                                .map(|d| d.clamp(0.0, 10.0) as usize)
                                .unwrap_or(2),
                        ),
                        args.get("grouping").and_then(Value::as_bool).unwrap_or(true),
                    );
                    let sign = if n < 0.0 { "-" } else { "" };
                    let code: String =
                        code.chars().filter(char::is_ascii_alphabetic).take(3).collect();
                    let s = match code.to_ascii_uppercase().as_str() {
                        "USD" => format!("{sign}${body}"),
                        "EUR" => format!("{sign}€{body}"),
                        "GBP" => format!("{sign}£{body}"),
                        "JPY" => format!("{sign}¥{body}"),
                        other => format!("{sign}{other} {body}"),
                    };
                    Value::String(s)
                }
                _ => Value::Null,
            }
        }
        "pluralize" => {
            let n = arg_f64(args, "value").unwrap_or(0.0);
            let pick = |k: &str| args.get(k).filter(|v| !v.is_null()).cloned();
            let chosen = if n == 0.0 {
                pick("zero")
            } else if n == 1.0 {
                pick("one")
            } else if n == 2.0 {
                pick("two")
            } else {
                None
            };
            chosen.or_else(|| pick("other")).unwrap_or(Value::Null)
        }
        "required" => Value::Bool(match &value {
            Value::Null => false,
            Value::String(s) => !s.trim().is_empty(),
            Value::Array(a) => !a.is_empty(),
            _ => true,
        }),
        "email" => Value::Bool(value.as_str().is_some_and(is_email)),
        "length" => {
            let len = match &value {
                Value::String(s) => s.chars().count(),
                Value::Array(a) => a.len(),
                _ => 0,
            } as f64;
            let ok = arg_f64(args, "min").is_none_or(|m| len >= m)
                && arg_f64(args, "max").is_none_or(|m| len <= m);
            Value::Bool(ok)
        }
        "numeric" => Value::Bool(match arg_f64(args, "value") {
            Some(n) => {
                arg_f64(args, "min").is_none_or(|m| n >= m)
                    && arg_f64(args, "max").is_none_or(|m| n <= m)
            }
            None => false,
        }),
        "regex" => {
            let pattern = args.get("pattern").and_then(Value::as_str).unwrap_or("");
            Value::Bool(regex_match(pattern, &text::display(&value)))
        }
        "and" | "or" => {
            let items = args.get("values").and_then(Value::as_array).cloned().unwrap_or_default();
            let mut it = items.iter().map(truthy);
            Value::Bool(if name == "and" { it.all(|b| b) } else { it.any(|b| b) })
        }
        "not" => Value::Bool(!truthy(&value)),
        _ => Value::Null,
    }
}

/// `regex` runs on Rust's linear-time engine (no backtracking blowup) with a
/// pattern length and compiled size cap. A pattern that does not compile
/// never matches.
pub fn regex_match(pattern: &str, value: &str) -> bool {
    if pattern.len() > caps::REGEX_PATTERN {
        return false;
    }
    regex::RegexBuilder::new(pattern)
        .size_limit(1 << 20)
        .dfa_size_limit(1 << 20)
        .build()
        .is_ok_and(|re| re.is_match(value))
}

fn is_email(s: &str) -> bool {
    let Some((local, domain)) = s.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && !domain.contains('@')
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !s.chars().any(char::is_whitespace)
}

pub fn format_number(n: f64, decimals: Option<usize>, grouping: bool) -> String {
    if !n.is_finite() {
        return String::new();
    }
    let raw = match decimals {
        Some(d) => format!("{n:.d$}"),
        None => {
            let s = Number::from_f64(n).map(|x| x.to_string()).unwrap_or_default();
            s.strip_suffix(".0").map(str::to_string).unwrap_or(s)
        }
    };
    if !grouping {
        return raw;
    }
    let (sign, rest) = raw.strip_prefix('-').map(|r| ("-", r)).unwrap_or(("", raw.as_str()));
    let (int, frac) = rest.split_once('.').map(|(a, b)| (a, Some(b))).unwrap_or((rest, None));
    let mut grouped = String::new();
    for (i, ch) in int.chars().enumerate() {
        if i > 0 && (int.len() - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(ch);
    }
    match frac {
        Some(f) => format!("{sign}{grouped}.{f}"),
        None => format!("{sign}{grouped}"),
    }
}

/// `formatString`: `${/abs/path}`, `${relative/path}` and
/// `${fn(name: arg, ...)}` with allowlisted functions; `\${` is a literal.
pub fn interpolate(s: &str, ctx: Ctx<'_>, depth: usize) -> String {
    let mut out = String::new();
    let mut i = 0;
    while let Some(rest) = s.get(i..).filter(|r| !r.is_empty()) {
        if rest.starts_with("\\${") {
            out.push_str("${");
            i += 3;
            continue;
        }
        if rest.starts_with("${")
            && let Some(end) = matching_close(s, i + 2)
        {
            let v = expr(s.get(i + 2..end).unwrap_or(""), ctx, depth + 1);
            out.push_str(&text::display(&v));
            i = end + 1;
            continue;
        }
        let ch = rest.chars().next().unwrap_or(' ');
        out.push(ch);
        i += ch.len_utf8();
    }
    out
}

/// Index of the `}` closing a `${` whose body starts at `from`.
fn matching_close(s: &str, from: usize) -> Option<usize> {
    let mut depth = 1usize;
    let mut i = from;
    while let Some(rest) = s.get(i..).filter(|r| !r.is_empty()) {
        if rest.starts_with("${") {
            depth += 1;
            i += 2;
            continue;
        }
        if rest.starts_with('}') {
            depth -= 1;
            if depth == 0 {
                return Some(i);
            }
        }
        i += rest.chars().next().map_or(1, char::len_utf8);
    }
    None
}

fn expr(inner: &str, ctx: Ctx<'_>, depth: usize) -> Value {
    if depth > MAX_DEPTH {
        return Value::Null;
    }
    let inner = inner.trim();
    if let Some(open) = inner.find('(') {
        let name = inner.get(..open).unwrap_or("");
        if inner.ends_with(')')
            && !name.is_empty()
            && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            let mut args = Map::new();
            for part in split_args(inner.get(open + 1..inner.len() - 1).unwrap_or("")) {
                if let Some((k, v)) = part.split_once(':') {
                    args.insert(k.trim().to_string(), arg(v, ctx, depth + 1));
                }
            }
            return call(name, &args, ctx, depth + 1);
        }
    }
    pointer::get(ctx.model, &pointer::absolute(ctx.scope, inner)).cloned().unwrap_or(Value::Null)
}

fn arg(raw: &str, ctx: Ctx<'_>, depth: usize) -> Value {
    let a = raw.trim();
    if a.starts_with("${") && matching_close(a, 2) == Some(a.len() - 1) {
        return expr(a.get(2..a.len() - 1).unwrap_or(""), ctx, depth);
    }
    for q in ['\'', '"'] {
        if a.len() >= 2 && a.starts_with(q) && a.ends_with(q) {
            return Value::String(a.get(1..a.len() - 1).unwrap_or("").to_string());
        }
    }
    if let Ok(n) = a.parse::<f64>() {
        return Number::from_f64(n).map(Value::Number).unwrap_or(Value::Null);
    }
    match a {
        "true" => Value::Bool(true),
        "false" => Value::Bool(false),
        "null" => Value::Null,
        _ if a.contains("${") => Value::String(interpolate(a, ctx, depth)),
        _ => expr(a, ctx, depth),
    }
}

/// Split on top-level commas (outside `${}`, parentheses and quotes).
fn split_args(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let (mut depth, mut quote, mut start) = (0i32, None::<char>, 0usize);
    for (i, ch) in s.char_indices() {
        match (quote, ch) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), _) => {}
            (None, '\'' | '"') => quote = Some(ch),
            (None, '{' | '(') => depth += 1,
            (None, '}' | ')') => depth -= 1,
            (None, ',') if depth == 0 => {
                out.push(s.get(start..i).unwrap_or(""));
                start = i + 1;
            }
            _ => {}
        }
    }
    if let Some(tail) = s.get(start..).filter(|t| !t.trim().is_empty()) {
        out.push(tail);
    }
    out
}
