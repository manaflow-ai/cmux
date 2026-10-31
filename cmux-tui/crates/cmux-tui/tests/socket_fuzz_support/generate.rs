//! Values for the catalog's type descriptors: valid, boundary (valid, at an
//! edge) and invalid (a sure violation of the descriptor).
//!
//! Safety: a field that names a program, a script or a URL never gets a
//! random value (`safe_value`), so a fuzzed request never runs an arbitrary
//! command or opens an arbitrary site. Terminals run a sink, not a shell.

use std::collections::BTreeMap;

use serde_json::{Map, Value, json};

use super::Rng;
use super::catalog::{Catalog, Operation};

/// Real ids the session has now, by resource kind, plus the test's folder.
#[derive(Default, Clone)]
pub struct Context {
    pub ids: BTreeMap<String, Vec<String>>,
    pub dir: String,
}

impl Context {
    /// Reads every `id` of the snapshot's resource arrays.
    pub fn from_snapshot(snapshot: &Value, dir: &str) -> Self {
        let mut ids: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for (array, kind) in [
            ("workspaces", "workspace"),
            ("screens", "screen"),
            ("panes", "pane"),
            ("tabs", "tab"),
            ("terminals", "terminal"),
            ("browsers", "browser"),
            ("clients", "client"),
            ("notifications", "notification"),
            ("agents", "agent"),
        ] {
            for item in snapshot[array].as_array().into_iter().flatten() {
                if let Some(id) = item["id"].as_str() {
                    ids.entry(kind.to_string()).or_default().push(id.to_string());
                }
            }
        }
        Self { ids, dir: dir.to_string() }
    }
}

pub fn id_prefix(kind: &str) -> &'static str {
    match kind {
        "machine" => "machine_",
        "session" => "session_",
        "client" => "client_",
        "workspace" => "ws_",
        "screen" => "screen_",
        "pane" => "pane_",
        "split" => "split_",
        "tab" => "tab_",
        "terminal" => "term_",
        "browser" => "browser_",
        "notification" => "notification_",
        "agent" => "agent_",
        "frontend_projection" => "projection_",
        "pairing_request" => "pairing_",
        "sidebar_view" => "sidebar_view_",
        "stream" => "stream_",
        _ => "x_",
    }
}

fn hex32(rng: &mut Rng) -> String {
    format!("{:016x}{:016x}", rng.next_u64(), rng.next_u64())
}

/// A field whose value must never be random: programs, scripts, URLs.
pub fn safe_value(field: &str, ctx: &Context, rng: &mut Rng) -> Option<Value> {
    Some(match field {
        "argv" => json!(["/bin/sh", "-c", "exec cat > /dev/null"]),
        "shell" | "command" | "initial_command" | "script" | "tmux_start_command"
        | "pane_start_command" | "start_command" | "resume_command" => {
            json!("exec cat > /dev/null")
        }
        "url" | "git_url" | "href" | "link" => {
            json!(*rng.pick(&["https://example.invalid/", "http://127.0.0.1:9/", "about:blank"]))
        }
        "cwd" | "folder" | "directory" | "dir" | "root" => json!(ctx.dir.clone()),
        "timeout_ms" | "wait_ms" | "timeout" => json!(format!("{}", rng.below(800))),
        _ => return None,
    })
}

const WORDS: &[&str] =
    &["alpha", "beta", "x", "work", "fuzz", "tab", "a b", "🦀", "ש", "e\u{301}", " ", ""];

fn valid_string(rng: &mut Rng, min: usize, max: Option<usize>) -> String {
    let mut text = (*rng.pick(WORDS)).to_string();
    if rng.chance(30) {
        text.push_str(&format!("-{}", rng.below(1000)));
    }
    while text.len() < min {
        text.push('a');
    }
    if let Some(max) = max {
        while text.len() > max {
            text.pop();
        }
        while text.len() < min {
            text.push('a');
        }
    }
    text
}

fn bounds(ty: &Value) -> (usize, Option<usize>) {
    let min = ty["min_length"].as_u64().unwrap_or(0) as usize;
    (min, ty["max_length"].as_u64().map(|m| m as usize))
}

pub struct Gen<'a> {
    pub catalog: &'a Catalog,
    pub ctx: &'a Context,
}

impl Gen<'_> {
    fn resolve<'v>(&'v self, ty: &'v Value) -> &'v Value {
        let mut ty = ty;
        for _ in 0..16 {
            if ty["kind"] == "ref" {
                match ty["name"].as_str().and_then(|n| self.catalog.type_named(n)) {
                    Some(next) => ty = next,
                    None => return ty,
                }
            } else {
                break;
            }
        }
        ty
    }

    pub fn valid(&self, ty: &Value, rng: &mut Rng, depth: usize) -> Value {
        if ty["kind"] == "ref" && ty["name"] == "JsonValue" {
            return json!({"k": "v"});
        }
        let ty = self.resolve(ty);
        match ty["kind"].as_str().unwrap_or_default() {
            "primitive" => self.valid_primitive(ty, rng),
            "enum" => ty["values"]
                .as_array()
                .and_then(|v| v.get(rng.below(v.len())).cloned())
                .unwrap_or(Value::Null),
            "nullable" => {
                if rng.chance(20) {
                    Value::Null
                } else {
                    self.valid(&ty["value"], rng, depth)
                }
            }
            "resource_id" => {
                json!(self.resource_id(ty["resource"].as_str().unwrap_or_default(), rng))
            }
            "selector" => json!(self.selector(ty["resource"].as_str().unwrap_or_default(), rng)),
            "array" => {
                let min = ty["min_items"].as_u64().unwrap_or(0) as usize;
                let max = ty["max_items"].as_u64().map(|m| m as usize).unwrap_or(3).min(3).max(min);
                let count = if depth > 3 { min } else { min + rng.below(max - min + 1) };
                Value::Array((0..count).map(|_| self.valid(&ty["items"], rng, depth + 1)).collect())
            }
            "map" => {
                if depth > 3 {
                    json!({})
                } else {
                    json!({"key": self.valid(&ty["values"], rng, depth + 1)})
                }
            }
            "object" => self.valid_object(ty, rng, depth),
            "union" => ty["variants"]
                .as_array()
                .and_then(|v| v.get(rng.below(v.len())))
                .map(|variant| self.valid(variant, rng, depth + 1))
                .unwrap_or(Value::Null),
            _ => json!({}),
        }
    }

    pub fn valid_object(&self, ty: &Value, rng: &mut Rng, depth: usize) -> Value {
        let mut object = Map::new();
        for (name, field) in ty["fields"].as_object().into_iter().flatten() {
            let required = field["required"].as_bool() == Some(true);
            if required || (depth < 3 && rng.chance(30)) {
                let value = safe_value(name, self.ctx, rng)
                    .unwrap_or_else(|| self.valid(&field["type"], rng, depth + 1));
                object.insert(name.clone(), value);
            }
        }
        Value::Object(object)
    }

    fn valid_primitive(&self, ty: &Value, rng: &mut Rng) -> Value {
        let min = ty["minimum"].as_f64();
        let max = ty["maximum"].as_f64();
        let number = |rng: &mut Rng, top: u64| -> u64 {
            let lo = min.unwrap_or(0.0).max(0.0) as u64;
            let hi = max.map(|m| m as u64).unwrap_or(top).max(lo);
            lo + (rng.next_u64() % (hi - lo).saturating_add(1).min(100))
        };
        match ty["name"].as_str().unwrap_or_default() {
            "string" => {
                let (lo, hi) = bounds(ty);
                json!(valid_string(rng, lo, hi))
            }
            "decimal" => json!(number(rng, 1000).to_string()),
            "uint32" | "uint16" => json!(number(rng, 100)),
            "int32" => json!(number(rng, 100) as i64),
            "float64" => json!(min.unwrap_or(0.0).max(0.25).min(max.unwrap_or(1.0))),
            "boolean" => json!(rng.chance(50)),
            "base64" => json!("aGVsbG8="),
            _ => json!({"any": [1, "two", null]}),
        }
    }

    /// A valid value at an edge of the descriptor (empty, longest, zero,
    /// largest, a well-formed id that names nothing).
    pub fn boundary(&self, ty: &Value, rng: &mut Rng) -> Value {
        let ty = self.resolve(ty);
        match (ty["kind"].as_str().unwrap_or_default(), ty["name"].as_str().unwrap_or_default()) {
            ("primitive", "string") => {
                let (lo, hi) = bounds(ty);
                let len = match (rng.below(3), hi) {
                    (0, _) => lo,
                    (_, Some(hi)) => hi,
                    (1, None) => 65_536,
                    _ => lo.max(1),
                };
                let unit = *rng.pick(&["a", "é", "🦀", "\u{202e}", "\u{200b}"]);
                let mut text = String::new();
                while text.len() + unit.len() <= len {
                    text.push_str(unit);
                }
                while text.len() < lo {
                    text.push('a');
                }
                json!(text)
            }
            ("primitive", "decimal") => json!(*rng.pick(&["0", "18446744073709551615", "1"])),
            ("primitive", "uint32") => json!(*rng.pick(&[0u64, u64::from(u32::MAX)])),
            ("primitive", "uint16") => json!(*rng.pick(&[0u64, u64::from(u16::MAX)])),
            ("primitive", "int32") => {
                json!(*rng.pick(&[i64::from(i32::MIN), i64::from(i32::MAX), 0]))
            }
            ("primitive", "float64") => json!(*rng.pick(&[0.0, 1.0, 1e308, -1e308, 5e-324])),
            ("resource_id", _) | ("selector", _) => {
                let kind = ty["resource"].as_str().unwrap_or_default();
                json!(format!("{}{}", id_prefix(kind), hex32(rng)))
            }
            ("array", _) => {
                let max = ty["max_items"].as_u64().map(|m| m as usize).unwrap_or(256).min(256);
                let min = ty["min_items"].as_u64().unwrap_or(0) as usize;
                let count = if rng.chance(50) { min } else { max };
                Value::Array((0..count).map(|_| self.valid(&ty["items"], rng, 4)).collect())
            }
            _ => self.valid(ty, rng, 2),
        }
    }

    /// A value that violates the descriptor for sure, with a short label.
    pub fn invalid(&self, ty: &Value, rng: &mut Rng) -> (Value, &'static str) {
        if ty["kind"] == "ref" && ty["name"] == "JsonValue" {
            return (Value::Null, "");
        }
        let ty = self.resolve(ty);
        let kind = ty["kind"].as_str().unwrap_or_default();
        let name = ty["name"].as_str().unwrap_or_default();
        let mut options: Vec<(Value, &'static str)> = Vec::new();
        match (kind, name) {
            ("primitive", "string") | ("primitive", "base64") => {
                options.push((json!(7), "number-for-string"));
                options.push((json!(["x"]), "array-for-string"));
                let (lo, hi) = bounds(ty);
                if let Some(hi) = hi {
                    options.push((json!("a".repeat(hi + 1)), "string-over-max"));
                }
                if lo > 0 {
                    options.push((json!(""), "string-under-min"));
                }
                if name == "base64" {
                    options.push((json!("@@not base64@@"), "bad-base64"));
                }
            }
            ("primitive", "decimal") => {
                options.push((json!(5), "number-for-decimal-string"));
                options.push((json!("-1"), "negative-decimal"));
                options.push((json!("1.5"), "fraction-decimal"));
                options.push((json!("18446744073709551616"), "decimal-over-u64"));
                options.push((json!(" 1"), "decimal-with-space"));
                options.push((json!(""), "empty-decimal"));
            }
            ("primitive", "uint32") | ("primitive", "uint16") | ("primitive", "int32") => {
                options.push((json!("5"), "string-for-integer"));
                options.push((json!(1.5), "fraction-for-integer"));
                let over = match name {
                    "uint16" => json!(65_536),
                    "uint32" => json!(4_294_967_296u64),
                    _ => json!(2_147_483_648u64),
                };
                options.push((over, "integer-over-max"));
                if name != "int32" {
                    options.push((json!(-1), "negative-unsigned"));
                }
            }
            ("primitive", "float64") => {
                options.push((json!("0.5"), "string-for-float"));
                options.push((json!([]), "array-for-float"));
            }
            ("primitive", "boolean") => {
                options.push((json!("true"), "string-for-boolean"));
                options.push((json!(1), "number-for-boolean"));
            }
            ("enum", _) => {
                options.push((json!("NOT_A_VARIANT"), "unknown-enum"));
                options.push((json!(3), "number-for-enum"));
            }
            ("resource_id", _) => {
                let kind = ty["resource"].as_str().unwrap_or_default();
                options
                    .push((json!(format!("{}{}", id_prefix(kind), "G".repeat(32))), "id-bad-hex"));
                options.push((json!(format!("{}{}", id_prefix(kind), "a".repeat(31))), "id-short"));
                options.push((json!(format!("nope_{}", hex32(rng))), "id-wrong-prefix"));
                options.push((json!(""), "id-empty"));
                options.push((json!(12), "id-number"));
            }
            ("selector", _) => {
                options.push((json!(""), "selector-empty"));
                options.push((json!(12), "selector-number"));
                options.push((json!("has_underscore"), "selector-reserved"));
            }
            ("array", _) => {
                options.push((json!("not an array"), "string-for-array"));
                if let Some(max) = ty["max_items"].as_u64().filter(|m| *m <= 10_000) {
                    let items = (0..=max).map(|_| self.valid(&ty["items"], rng, 4)).collect();
                    options.push((Value::Array(items), "array-over-max-items"));
                }
                if ty["min_items"].as_u64().unwrap_or(0) > 0 {
                    options.push((json!([]), "array-under-min-items"));
                }
            }
            ("map", _) => options.push((json!(["not", "a", "map"]), "array-for-map")),
            ("object", _) => {
                options.push((json!("not an object"), "string-for-object"));
                if ty["extra"] == false {
                    let mut object = self.valid_object(ty, rng, 2);
                    object["__fuzz_unknown"] = json!(1);
                    options.push((object, "object-unknown-field"));
                }
            }
            _ => {}
        }
        if options.is_empty() {
            return (Value::Null, "");
        }
        let index = rng.below(options.len());
        options.swap_remove(index)
    }
}

/// The selectors and fields of one valid request for `op`.
pub fn valid_params(generator: &Gen<'_>, op: &Operation, rng: &mut Rng) -> Map<String, Value> {
    let mut params = Map::new();
    for (selector, required) in &op.selectors {
        if *required || rng.chance(25) {
            params.insert(selector.clone(), json!(generator.selector(selector, rng)));
        }
    }
    for (name, (required, ty)) in &op.fields {
        // A wait always carries a short timeout, so a valid wait never hangs.
        let bounded = name.contains("timeout") || name == "wait_ms";
        if *required || bounded || rng.chance(30) {
            let value =
                safe_value(name, generator.ctx, rng).unwrap_or_else(|| generator.valid(ty, rng, 0));
            params.insert(name.clone(), value);
        }
    }
    // `one_of`: keep the first alternative's required fields, drop its forbidden ones.
    if let Some(first) = op.one_of.first() {
        for name in first["forbidden"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            params.remove(name);
        }
        for name in first["required"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            if !params.contains_key(name) && name != "idempotency_key" {
                if let Some((_, ty)) = op.fields.get(name) {
                    let value = safe_value(name, generator.ctx, rng)
                        .unwrap_or_else(|| generator.valid(ty, rng, 0));
                    params.insert(name.to_string(), value);
                }
            }
        }
    }
    params
}

impl Gen<'_> {
    pub fn resource_id(&self, kind: &str, rng: &mut Rng) -> String {
        match self.ctx.ids.get(kind) {
            Some(ids) if !ids.is_empty() && rng.chance(85) => rng.pick(ids).clone(),
            _ => format!("{}{}", id_prefix(kind), hex32(rng)),
        }
    }

    pub fn selector(&self, kind: &str, rng: &mut Rng) -> String {
        if kind == "machine" || kind == "session" {
            return "current".to_string();
        }
        match rng.below(10) {
            0 => "current".to_string(),
            1 => "name:fuzz".to_string(),
            _ => self.resource_id(kind, rng),
        }
    }
}
