//! `cmux ext preview DIR... [--out FILE] [--check] [--json]`: the auto gallery's states for
//! every widget in DIR (RFD 0009 part 5, "the auto gallery").
//!
//! A widget records the scenes it draws in `preview/scenes.json`, the first-party widgets'
//! shape: an object of states by name, each `{"size": "small" | "medium" | "large", "ops":
//! [scene ops]}` (`first-party-apps/widget-clock/preview/build.ts`; the example widgets' are
//! written by `cmux-app-host/js/test/widgets.test.ts`). For each size class the widget
//! declares (`implements["cmux.widget/1"].options.sizes`, else its `size` setting's enum, else
//! the sizes it recorded) this adds the states a person must see before the widget ships:
//!
//! - `long-text`: the size's base state with every word on screen (`text`, `title`, ...) made
//!   about three times longer, so an unlimited Text or a missing truncation shows.
//! - `empty`: the base state with its repeated rows (three or more siblings of one shape, or
//!   a `ForEach`'s children) taken out: the widget with no items.
//! - `error`: the tile the host draws when the render export throws (`SceneFailure.tsx`).
//!
//! A recorded state whose name says what it is (`small-empty`, `medium-offline`, ...) is the
//! widget's own and wins: nothing is derived for that size and kind. Each state carries the
//! design check's findings (`design.rs`, against the folder's `cmux-design.json` when it has
//! one), so the gallery shows the warnings beside the tile.
//!
//! DIR is a widget folder, or a folder of them (`examples/extensions`, `first-party-apps`).
//! `--out` writes the gallery file (`webviews/src/apps/scene/fixtures/widget-previews.json`);
//! `--check` exits 1 when that file differs from what the folders record now.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use super::design::{self, Surface};
use super::design_system::System;
use super::exit;
use super::scene;

/// The file a widget's recorded states live in, under its folder.
pub(super) const SCENES: &str = "preview/scenes.json";

/// Size classes in the order a gallery shows them; another declared size follows these.
const SIZES: [&str; 3] = ["small", "medium", "large"];

/// The props whose strings are words on screen (the outline's, `scene.rs`).
const WORDS: [&str; 6] = ["text", "title", "subtitle", "label", "message", "placeholder"];

/// Words a long-text state appends, in turn: long compounds and plain words, so a renderer
/// that wraps only at spaces and one that breaks words both show.
const FILLER: [&str; 9] = [
    "Internationalization",
    "and",
    "Verschlimmbesserung",
    "with",
    "a",
    "much",
    "longer",
    "label",
    "than planned",
];

/// Siblings of one shape that make a list a derived empty state takes out.
const MIN_ROWS: usize = 3;

/// The reason a derived error state's host failure shows: a render that read missing data.
pub(super) const DERIVED_FAILURE: &str =
    "render: TypeError: Cannot read properties of undefined (reading 'items')";

/// `ext preview`'s options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) struct PreviewOptions {
    pub dirs: Vec<PathBuf>,
    /// `--out FILE`: where the gallery file goes; none prints it.
    pub out: Option<PathBuf>,
    /// `--check`: compare with `--out` instead of writing it.
    pub check: bool,
}

/// What a state shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum Kind {
    /// A state the widget recorded as it is (data, a setting, a locale).
    Recorded,
    LongText,
    Empty,
    Error,
}

impl Kind {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Recorded => "recorded",
            Self::LongText => "long-text",
            Self::Empty => "empty",
            Self::Error => "error",
        }
    }

    /// What a recorded state's name says it is: `-empty`, `-none` or `-nothing` an empty state;
    /// `-error`, `-failed`, `-offline`, `-no-network` or `-denied` an error; `-long` long text.
    pub(super) fn of(name: &str) -> Self {
        let words: Vec<&str> = name.split(['-', '_', '.', ' ']).collect();
        let has = |w: &str| words.iter().any(|word| word.eq_ignore_ascii_case(w));
        let pair = |a: &str, b: &str| words.windows(2).any(|p| p[0] == a && p[1] == b);
        if has("error") || has("failed") || has("failure") || has("offline") || has("denied") {
            Self::Error
        } else if pair("no", "network") {
            Self::Error
        } else if has("empty") || has("none") || has("nothing") {
            Self::Empty
        } else if has("long") {
            Self::LongText
        } else {
            Self::Recorded
        }
    }
}

/// `text` about three times longer (at least 28 characters), in the same case; a string with
/// no letter (a number, a time, an emoji) stays as it is.
pub(super) fn lengthen(text: &str) -> String {
    if !text.chars().any(char::is_alphabetic) {
        return text.to_string();
    }
    let target = (text.chars().count() * 3).max(28);
    let upper = text.chars().filter(|c| c.is_alphabetic()).all(char::is_uppercase);
    let mut out = text.to_string();
    for word in FILLER.iter().cycle() {
        if out.chars().count() >= target {
            break;
        }
        out.push(' ');
        out.push_str(word);
    }
    if upper { out.to_uppercase() } else { out }
}

/// A scene's final tree: its root and nodes, from any op batches.
struct Tree {
    root: String,
    nodes: BTreeMap<String, scene::Node>,
}

impl Tree {
    fn of(ops: &Value) -> Option<Self> {
        let (root, nodes) = scene::apply(&[ops]);
        let root = root.filter(|r| nodes.contains_key(r))?;
        Some(Self { root, nodes })
    }

    /// The tree as one batch from empty: a create per node reachable from the root (depth
    /// first), then each one's children, then the root.
    fn ops(&self) -> Vec<Value> {
        let mut creates = Vec::new();
        let mut children = Vec::new();
        let mut seen = BTreeSet::new();
        let mut stack = vec![(self.root.clone(), 0usize)];
        while let Some((id, depth)) = stack.pop() {
            if depth > 64 || !seen.insert(id.clone()) {
                continue;
            }
            let Some(node) = self.nodes.get(&id) else { continue };
            creates.push(json!({"op": "create", "id": id, "type": node.kind, "props": node.props}));
            let live: Vec<&String> =
                node.children.iter().filter(|c| self.nodes.contains_key(*c)).collect();
            if !live.is_empty() {
                children.push(json!({"op": "children", "id": id, "children": live}));
            }
            stack.extend(live.into_iter().rev().map(|c| (c.clone(), depth + 1)));
        }
        creates.extend(children);
        creates.push(json!({"op": "root", "id": self.root}));
        creates
    }

    /// A node's shape: its type and its children's shapes, two levels down.
    fn shape(&self, id: &str, depth: usize) -> String {
        let Some(node) = self.nodes.get(id) else { return String::new() };
        if depth == 0 || node.children.is_empty() {
            return node.kind.clone();
        }
        let inner: Vec<String> = node.children.iter().map(|c| self.shape(c, depth - 1)).collect();
        format!("{}({})", node.kind, inner.join(","))
    }
}

/// `ops` with every word on screen lengthened (`lengthen`).
pub(super) fn long_text(ops: &Value) -> Option<Vec<Value>> {
    let mut tree = Tree::of(ops)?;
    for node in tree.nodes.values_mut() {
        for key in WORDS {
            if let Some(Value::String(text)) = node.props.get_mut(key) {
                *text = lengthen(text);
            }
        }
    }
    Some(tree.ops())
}

/// `ops` with its repeated rows taken out: every child of a `ForEach`, and each run of
/// `MIN_ROWS` or more siblings of one shape that are not bare leaves. None when the scene has
/// no list to empty.
pub(super) fn emptied(ops: &Value) -> Option<Vec<Value>> {
    let mut tree = Tree::of(ops)?;
    let mut cut: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (id, node) in &tree.nodes {
        if node.children.is_empty() {
            continue;
        }
        if node.kind == "ForEach" {
            cut.insert(id.clone(), Vec::new());
            continue;
        }
        let shapes: Vec<String> = node.children.iter().map(|c| tree.shape(c, 2)).collect();
        let mut keep = Vec::new();
        let mut i = 0;
        let mut changed = false;
        while i < node.children.len() {
            let mut j = i + 1;
            while j < node.children.len() && shapes[j] == shapes[i] {
                j += 1;
            }
            let leaf = !shapes[i].contains('(');
            if j - i >= MIN_ROWS && !leaf {
                changed = true;
            } else {
                keep.extend(node.children[i..j].iter().cloned());
            }
            i = j;
        }
        if changed {
            cut.insert(id.clone(), keep);
        }
    }
    if cut.is_empty() {
        return None;
    }
    for (id, keep) in cut {
        if let Some(node) = tree.nodes.get_mut(&id) {
            node.children = keep;
        }
    }
    Some(tree.ops())
}

/// The design findings a gallery tile shows: check, count and message.
fn warnings(ops: &[Value], system: &System) -> Value {
    let batch = Value::Array(ops.to_vec());
    let findings = design::check_in(&[&batch], Surface::Widget, system);
    Value::Array(
        findings
            .iter()
            .map(|f| json!({"check": f.check, "count": f.count, "message": f.message}))
            .collect(),
    )
}

/// The size classes a widget declares, gallery order first.
pub(super) fn declared_sizes(manifest: &Value, recorded: &[&str]) -> Vec<String> {
    let strings = |v: Option<&Value>| -> Vec<String> {
        v.and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default()
    };
    let mut sizes = strings(manifest.pointer("/implements/cmux.widget~11/options/sizes"));
    if sizes.is_empty() {
        sizes = strings(manifest.pointer("/settings/properties/size/enum"));
    }
    if sizes.is_empty() {
        sizes = recorded.iter().map(|s| s.to_string()).collect();
    }
    let rank = |s: &String| SIZES.iter().position(|k| k == s).unwrap_or(SIZES.len());
    let mut out: Vec<String> = Vec::new();
    for size in sizes {
        if !out.contains(&size) {
            out.push(size);
        }
    }
    out.sort_by_key(rank);
    out
}

/// A manifest's display name: `name.en`, a plain `name`, or the id.
fn display_name(manifest: &Value, fallback: &str) -> String {
    manifest
        .pointer("/name/en")
        .or_else(|| manifest.get("name").filter(|n| n.is_string()))
        .and_then(Value::as_str)
        .or_else(|| manifest.get("id").and_then(Value::as_str))
        .unwrap_or(fallback)
        .to_string()
}

/// One widget's gallery record from its manifest and `preview/scenes.json`.
pub(super) fn widget(
    dir: &str,
    manifest: &Value,
    scenes: &Value,
    system: &System,
) -> Result<Value, String> {
    let Some(recorded) = scenes.as_object() else {
        return Err(format!("{dir}/{SCENES} is not an object of states by name"));
    };
    let mut by_size: BTreeMap<String, Vec<(&String, Kind, &Value)>> = BTreeMap::new();
    for (name, state) in recorded {
        let size = state.get("size").and_then(Value::as_str);
        let ops = state.get("ops").filter(|o| o.is_array());
        let (Some(size), Some(ops)) = (size, ops) else {
            return Err(format!("{dir}/{SCENES}: state \"{name}\" needs a size and ops"));
        };
        by_size.entry(size.to_string()).or_default().push((name, Kind::of(name), ops));
    }
    let recorded_sizes: Vec<&str> = by_size.keys().map(String::as_str).collect();
    let sizes = declared_sizes(manifest, &recorded_sizes);
    let mut states = Vec::new();
    let mut missing = Vec::new();
    let state = |name: &str, size: &str, kind: Kind, from: Option<&str>, ops: Vec<Value>| {
        let mut s = Map::new();
        s.insert("name".into(), json!(name));
        s.insert("size".into(), json!(size));
        s.insert("kind".into(), json!(kind.name()));
        if let Some(from) = from {
            s.insert("from".into(), json!(from));
        }
        s.insert("warnings".into(), warnings(&ops, system));
        s.insert("ops".into(), Value::Array(ops));
        Value::Object(s)
    };
    for size in &sizes {
        let Some(list) = by_size.get(size) else {
            missing.push(json!({"size": size, "kind": "recorded",
                "fix": format!("record a \"{size}\" state in {SCENES}")}));
            continue;
        };
        let base = list
            .iter()
            .find(|(name, _, _)| name.as_str() == size)
            .or_else(|| list.iter().find(|(_, kind, _)| *kind == Kind::Recorded));
        let mut kinds: Vec<&(&String, Kind, &Value)> = list.iter().collect();
        kinds.sort_by_key(|(name, kind, _)| {
            (*kind, base.is_some_and(|b| b.0 != *name), (*name).clone())
        });
        for (name, kind, ops) in kinds {
            let ops = Tree::of(ops).map(|t| t.ops()).unwrap_or_default();
            states.push(state(name, size, *kind, None, ops));
        }
        let has = |kind: Kind| list.iter().any(|(_, k, _)| *k == kind);
        let Some((base_name, _, base_ops)) = base else { continue };
        let derived_name = |kind: Kind| format!("{size}-{}", kind.name());
        if !has(Kind::LongText)
            && let Some(ops) = long_text(base_ops)
        {
            states.push(state(
                &derived_name(Kind::LongText),
                size,
                Kind::LongText,
                Some(base_name),
                ops,
            ));
        }
        if !has(Kind::Empty) {
            match emptied(base_ops) {
                Some(ops) => states.push(state(&derived_name(Kind::Empty), size, Kind::Empty, Some(base_name), ops)),
                None => missing.push(json!({"size": size, "kind": "empty",
                    "fix": format!("\"{base_name}\" has no list to empty: record a \"{size}-empty\" state (no data yet) in {SCENES}")})),
            }
        }
        if !has(Kind::Error) {
            states.push(json!({"name": derived_name(Kind::Error), "size": size, "kind": "error",
                "from": base_name, "failed": DERIVED_FAILURE, "warnings": []}));
        }
    }
    Ok(json!({
        "dir": dir,
        "id": manifest.get("id").and_then(Value::as_str).unwrap_or(dir),
        "name": display_name(manifest, dir),
        "sizes": sizes,
        "states": states,
        "missing": missing,
    }))
}

/// The widget folders under `dir`: itself when it records states, else its children that do.
pub(super) fn widget_dirs(dir: &Path) -> Vec<PathBuf> {
    if dir.join(SCENES).is_file() {
        return vec![dir.to_path_buf()];
    }
    let mut out: Vec<PathBuf> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join(SCENES).is_file())
        .collect();
    out.sort();
    out
}

fn read_json(path: &Path) -> Result<Value, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

/// The gallery file for every widget under `dirs`, read from `base` (relative `dirs` join it)
/// and named as given, so the file is the same from any checkout.
pub(super) fn gallery(base: &Path, dirs: &[PathBuf]) -> Result<Value, String> {
    let mut widgets = Vec::new();
    for dir in dirs {
        let found = widget_dirs(&base.join(dir));
        if found.is_empty() {
            return Err(format!("{}: no {SCENES} here or in a folder under it", dir.display()));
        }
        for path in found {
            let folder = path.as_path();
            let shown = match path.file_name() {
                Some(leaf) if path != base.join(dir) => dir.join(leaf),
                _ => dir.clone(),
            };
            let manifest = read_json(&folder.join("cmux-app.json")).unwrap_or(Value::Null);
            let scenes = read_json(&folder.join(SCENES))?;
            let (system, _) = System::load(folder);
            let name = shown.to_string_lossy().trim_end_matches('/').to_string();
            widgets.push(widget(&name, &manifest, &scenes, &system)?);
        }
    }
    Ok(json!({
        "about": "cmux ext preview: each widget's recorded preview states and the long-text, empty and error states derived from them; regenerate, do not edit",
        "widgets": widgets,
    }))
}

/// The gallery file's text: indented, with one scene op per line, so a diff of a design change
/// reads as the nodes it touched.
pub(super) fn render(value: &Value) -> String {
    let mut out = String::new();
    write(&mut out, value, 0, false);
    out.push('\n');
    out
}

fn write(out: &mut String, value: &Value, depth: usize, ops: bool) {
    let pad = |n: usize| " ".repeat(n);
    match value {
        Value::Object(map) if !map.is_empty() => {
            out.push_str("{\n");
            for (i, (key, v)) in map.iter().enumerate() {
                out.push_str(&pad(depth + 1));
                out.push_str(&Value::String(key.clone()).to_string());
                out.push_str(": ");
                write(out, v, depth + 1, key == "ops");
                if i + 1 < map.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            out.push_str(&pad(depth));
            out.push('}');
        }
        Value::Array(items) if !items.is_empty() => {
            out.push_str("[\n");
            for (i, v) in items.iter().enumerate() {
                out.push_str(&pad(depth + 1));
                if ops || !(v.is_object() || v.is_array()) {
                    out.push_str(&v.to_string());
                } else {
                    write(out, v, depth + 1, false);
                }
                if i + 1 < items.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            out.push_str(&pad(depth));
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// A count per kind, for the summary line.
fn summary(gallery: &Value) -> String {
    let widgets = gallery["widgets"].as_array().map(Vec::as_slice).unwrap_or_default();
    let mut kinds: BTreeMap<&str, usize> = BTreeMap::new();
    let mut missing = 0;
    for w in widgets {
        for s in w["states"].as_array().into_iter().flatten() {
            *kinds.entry(s["kind"].as_str().unwrap_or("?")).or_default() += 1;
        }
        missing += w["missing"].as_array().map_or(0, Vec::len);
    }
    let kinds: Vec<String> = kinds.iter().map(|(k, n)| format!("{n} {k}")).collect();
    let total: usize = widgets.iter().map(|w| w["states"].as_array().map_or(0, Vec::len)).sum();
    format!("{} widgets, {total} states ({}), {missing} missing", widgets.len(), kinds.join(", "))
}

/// Runs `ext preview`. Exit 0 written or current, 1 stale (`--check`), 4 a folder that does
/// not read.
pub(super) fn run(options: &PreviewOptions, json_out: bool) -> i32 {
    let gallery = match gallery(Path::new(""), &options.dirs) {
        Ok(gallery) => gallery,
        Err(problem) => {
            eprintln!("cmux: ext preview: {problem}");
            return exit::MANIFEST_INVALID;
        }
    };
    let text = render(&gallery);
    let line = summary(&gallery);
    let Some(out) = &options.out else {
        print!("{text}");
        return exit::OK;
    };
    if options.check {
        let current =
            std::fs::read_to_string(out).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok());
        // Compared as data: a formatter may lay the file out its own way.
        let fresh = current.as_ref() == Some(&gallery);
        if json_out {
            println!(
                "{}",
                json!({"file": out, "current": fresh, "summary": line, "missing": missing_of(&gallery)})
            );
        } else if fresh {
            println!("{} is current: {line}", out.display());
        } else {
            eprintln!(
                "{} is stale: run cmux ext preview {} --out {}",
                out.display(),
                options.dirs.iter().map(|d| d.display().to_string()).collect::<Vec<_>>().join(" "),
                out.display()
            );
        }
        return if fresh { exit::OK } else { exit::LOAD_FAILED };
    }
    if let Err(e) = std::fs::write(out, &text) {
        eprintln!("cmux: ext preview: {}: {e}", out.display());
        return exit::MANIFEST_INVALID;
    }
    if json_out {
        println!("{}", json!({"file": out, "summary": line, "missing": missing_of(&gallery)}));
    } else {
        println!("wrote {}: {line}", out.display());
        for m in missing_of(&gallery).as_array().into_iter().flatten() {
            println!(
                "  missing {} {} state: {}",
                m["widget"].as_str().unwrap_or("?"),
                m["size"].as_str().unwrap_or("?"),
                m["fix"].as_str().unwrap_or("")
            );
        }
    }
    exit::OK
}

/// Every widget's missing states, each with the widget's id.
fn missing_of(gallery: &Value) -> Value {
    Value::Array(
        gallery["widgets"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|w| {
                let id = w["id"].clone();
                w["missing"].as_array().cloned().unwrap_or_default().into_iter().map(
                    move |mut m| {
                        m["widget"] = id.clone();
                        m
                    },
                )
            })
            .collect(),
    )
}

#[cfg(test)]
#[path = "preview_tests.rs"]
mod tests;
