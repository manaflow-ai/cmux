//! Writes the SDK's table (`$OUT_DIR/api.rs`) from the runtime's own sources, the ones the
//! TypeScript package imports: the event streams (`schema/v2/events.json`), the op scopes
//! (`generated/scopes.json`), the live sources (`generated/signals.json`) and the runtime's
//! version (`js/src/index.ts`), all in `cmux-app-host`. Nothing generated is committed.

use serde_json::Value;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

type Result<T> = std::result::Result<T, String>;

fn main() -> Result<()> {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").map_err(|e| e.to_string())?;
    let host = Path::new(&manifest_dir).join("../cmux-app-host");
    let events = host.join("schema/v2/events.json");
    let scopes = host.join("generated/scopes.json");
    let signals = host.join("generated/signals.json");
    let runtime = host.join("js/src/index.ts");
    for path in [&events, &scopes, &signals, &runtime] {
        println!("cargo::rerun-if-changed={}", path.display());
    }
    let out = std::env::var("OUT_DIR").map_err(|e| e.to_string())?;
    let source = api(&json(&events)?, &json(&scopes)?, &json(&signals)?, &text(&runtime)?)?;
    std::fs::write(PathBuf::from(out).join("api.rs"), source).map_err(|e| e.to_string())
}

fn text(path: &Path) -> Result<String> {
    std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn json(path: &Path) -> Result<Value> {
    serde_json::from_str(&text(path)?).map_err(|e| format!("{}: {e}", path.display()))
}

fn str_at<'a>(value: &'a Value, key: &str, what: &str) -> Result<&'a str> {
    value.get(key).and_then(Value::as_str).ok_or_else(|| format!("{what}: no string {key}"))
}

fn list_at(value: &Value, key: &str, what: &str) -> Result<String> {
    let items =
        value.get(key).and_then(Value::as_array).ok_or_else(|| format!("{what}: no list {key}"))?;
    let strings = items
        .iter()
        .map(|item| {
            item.as_str()
                .map(|s| format!("{s:?}"))
                .ok_or_else(|| format!("{what}: {key} holds a non-string"))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(format!("&[{}]", strings.join(", ")))
}

fn api(events: &Value, scopes: &Value, signals: &Value, runtime: &str) -> Result<String> {
    let api_version = str_at(scopes, "apiVersion", "scopes.json")?;
    let runtime_version = runtime
        .lines()
        .find_map(|line| line.strip_prefix("export const RUNTIME_VERSION = \""))
        .and_then(|rest| rest.strip_suffix('"'))
        .ok_or("js/src/index.ts: no RUNTIME_VERSION")?;
    let ops = scopes.get("ops").ok_or("scopes.json: no ops")?;
    let mut out = String::new();
    let w = |e: std::fmt::Error| e.to_string();
    writeln!(out, "/// The app API this crate describes (`cmux app API` in cmux-app.d.ts).")
        .map_err(w)?;
    writeln!(out, "pub const API_VERSION: &str = {api_version:?};").map_err(w)?;
    writeln!(out, "/// The extension runtime this crate was built against.").map_err(w)?;
    writeln!(out, "pub const RUNTIME_VERSION: &str = {runtime_version:?};").map_err(w)?;
    writeln!(out, "/// Every event stream an extension can subscribe to.").map_err(w)?;
    writeln!(out, "pub const EVENTS: &[Event] = &[").map_err(w)?;
    // serde_json's map is sorted, so the table is in name order like the TypeScript one.
    for (name, event) in
        events.get("events").and_then(Value::as_object).ok_or("events.json: no events")?
    {
        let reads = str_at(event, "reads", name)?;
        let scope = ops.get(reads).map(|op| str_at(op, "scope", reads)).transpose()?;
        let scope = scope
            .ok_or_else(|| format!("events.json: {name} reads {reads}, which apps cannot call"))?;
        let docs = str_at(event, "docs", name)?;
        writeln!(
            out,
            "    Event {{ name: {name:?}, docs: {docs:?}, reads: {reads:?}, scope: {scope:?} }},"
        )
        .map_err(w)?;
    }
    writeln!(out, "];").map_err(w)?;
    writeln!(out, "/// Every live source `cmux.watch` reads.").map_err(w)?;
    writeln!(out, "pub const SIGNALS: &[Signal] = &[").map_err(w)?;
    for (name, signal) in
        signals.get("signals").and_then(Value::as_object).ok_or("signals.json: no signals")?
    {
        let docs = str_at(signal, "docs", name)?;
        let scopes = list_at(signal, "scopes", name)?;
        let push = list_at(signal, "push", name)?;
        writeln!(
            out,
            "    Signal {{ name: {name:?}, docs: {docs:?}, scopes: {scopes}, push: {push} }},"
        )
        .map_err(w)?;
    }
    writeln!(out, "];").map_err(w)?;
    Ok(out)
}
