//! The CI guard: a protocol change that can break an older or newer peer
//! must come with a compat rule.
//!
//! The protocol surface is flattened from the SDK schema IR
//! (`cmux-tui/spec/sdk-schema.json`) into one entry per
//! `(message kind, JSON pointer)`. A snapshot of that surface is checked in
//! next to the compat file, stamped with the revision it matches. When the
//! schema changes, every *breaking* difference against the snapshot must be
//! covered by a rule in a revision newer than the snapshot; only then may the
//! snapshot be rewritten. Purely additive differences (a new optional
//! request member, a new response member, a new command or event) need no
//! rule, but the snapshot must still be refreshed so the next change is
//! diffed against the truth.
//!
//! Message kinds: `request:<cmd>` (pointers relative to the request line,
//! whose arguments sit at the top level), `response:<cmd>` (relative to the
//! reply line, so the result is under `/data`), `event:<name>` (relative to
//! the event line).

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::change::Change;
use crate::pointer::{self, WILDCARD};
use crate::schema::Schema;

/// The shape of one member of the surface.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Shape {
    /// Type summary (`string`, `uint64`, `object`, `array`, `map`, `enum`, `json`, ...).
    pub ty: String,
    /// The member must be present.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub required: bool,
    /// The member may be `null`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub nullable: bool,
    /// Allowed values for enums and literals.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub values: BTreeSet<String>,
}

/// Message kind -> pointer -> shape.
pub type Surface = BTreeMap<String, BTreeMap<String, Shape>>;

/// The checked-in snapshot.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    /// The compat revision this surface matches.
    pub revision: u32,
    /// The flattened surface.
    pub surface: Surface,
}

/// Who writes a message kind, which decides what breaks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Writer {
    Client,
    Server,
}

fn writer_of(kind: &str) -> Writer {
    if kind.starts_with("request:") { Writer::Client } else { Writer::Server }
}

/// Flattens the SDK schema IR into a surface.
pub fn surface_from_sdk_schema(schema: &Value) -> Surface {
    let types = schema.get("types").and_then(Value::as_object).cloned().unwrap_or_default();
    let flattener = Flattener { types };
    let mut surface = Surface::new();
    if let Some(commands) = schema.get("commands").and_then(Value::as_object) {
        for (name, command) in commands {
            if let Some(request) = command.get("request") {
                let mut entries = BTreeMap::new();
                flattener.walk(request, "", &mut entries, &mut Vec::new(), true);
                surface.insert(format!("request:{name}"), entries);
            }
            if let Some(result) = command.get("result") {
                let mut entries = BTreeMap::new();
                flattener.walk(result, "/data", &mut entries, &mut Vec::new(), true);
                surface.insert(format!("response:{name}"), entries);
            }
        }
    }
    if let Some(events) = schema.get("events").and_then(Value::as_object) {
        for (name, event) in events {
            if let Some(payload) = event.get("payload") {
                let mut entries = BTreeMap::new();
                flattener.walk(payload, "", &mut entries, &mut Vec::new(), true);
                surface.insert(format!("event:{name}"), entries);
            }
        }
    }
    surface
}

struct Flattener {
    types: serde_json::Map<String, Value>,
}

const MAX_DEPTH: usize = 16;

impl Flattener {
    fn leaf(entries: &mut BTreeMap<String, Shape>, at: &str, shape: Shape) {
        match entries.get_mut(at) {
            None => {
                entries.insert(at.to_owned(), shape);
            }
            // Union variants share pointers: merge them.
            Some(existing) => {
                if existing.ty != shape.ty && !existing.ty.split('|').any(|t| t == shape.ty) {
                    existing.ty = format!("{}|{}", existing.ty, shape.ty);
                }
                existing.required &= shape.required;
                existing.nullable |= shape.nullable;
                existing.values.extend(shape.values);
            }
        }
    }

    fn walk(
        &self,
        ty: &Value,
        at: &str,
        entries: &mut BTreeMap<String, Shape>,
        stack: &mut Vec<String>,
        required: bool,
    ) {
        self.walk_nullable(ty, at, entries, stack, required, false);
    }

    fn walk_nullable(
        &self,
        ty: &Value,
        at: &str,
        entries: &mut BTreeMap<String, Shape>,
        stack: &mut Vec<String>,
        required: bool,
        nullable: bool,
    ) {
        let shape = |ty: &str, values: BTreeSet<String>| Shape {
            ty: ty.to_owned(),
            required,
            nullable,
            values,
        };
        if stack.len() > MAX_DEPTH {
            Self::leaf(entries, at, shape("deep", BTreeSet::new()));
            return;
        }
        let kind = ty.get("kind").and_then(Value::as_str).unwrap_or("unknown");
        match kind {
            "scalar" => {
                let name = ty.get("name").and_then(Value::as_str).unwrap_or("scalar");
                Self::leaf(entries, at, shape(name, BTreeSet::new()));
            }
            "literal" => {
                let value = ty.get("value").map(Value::to_string).unwrap_or_default();
                Self::leaf(entries, at, shape("literal", BTreeSet::from([value])));
            }
            "enum" => {
                let values = ty
                    .get("values")
                    .and_then(Value::as_array)
                    .map(|vs| {
                        vs.iter()
                            .map(|v| v.as_str().map_or_else(|| v.to_string(), str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default();
                Self::leaf(entries, at, shape("enum", values));
            }
            "ref" => {
                let name = ty.get("name").and_then(Value::as_str).unwrap_or_default().to_owned();
                if stack.contains(&name) {
                    Self::leaf(entries, at, shape(&format!("ref:{name}"), BTreeSet::new()));
                    return;
                }
                let Some(target) = self.types.get(&name) else {
                    Self::leaf(entries, at, shape(&format!("ref:{name}"), BTreeSet::new()));
                    return;
                };
                stack.push(name);
                self.walk_nullable(target, at, entries, stack, required, nullable);
                stack.pop();
            }
            "alias" => {
                if let Some(target) = ty.get("target") {
                    self.walk_nullable(target, at, entries, stack, required, nullable);
                }
            }
            "object" => {
                if !at.is_empty() && at != "/data" {
                    Self::leaf(entries, at, shape("object", BTreeSet::new()));
                }
                if let Some(fields) = ty.get("fields").and_then(Value::as_object) {
                    for (name, field) in fields {
                        let child = format!("{at}/{}", pointer::escape(name));
                        let required =
                            field.get("presence").and_then(Value::as_str) == Some("required");
                        let nullable =
                            field.get("nullable").and_then(Value::as_bool).unwrap_or(false);
                        if let Some(field_ty) = field.get("type") {
                            self.walk_nullable(
                                field_ty, &child, entries, stack, required, nullable,
                            );
                        }
                    }
                }
            }
            "array" | "map" => {
                Self::leaf(entries, at, shape(kind, BTreeSet::new()));
                let inner =
                    ty.get("items").or_else(|| ty.get("values")).or_else(|| ty.get("value"));
                if let Some(inner) = inner {
                    self.walk(inner, &format!("{at}/{WILDCARD}"), entries, stack, false);
                }
            }
            "tagged_union" => {
                let variants = ty.get("variants").and_then(Value::as_object);
                let names = variants.map(|v| v.keys().cloned().collect()).unwrap_or_default();
                Self::leaf(entries, at, shape("tagged_union", names));
                for variant in variants.into_iter().flat_map(|v| v.values()) {
                    // A member of one variant is not required in the union.
                    self.walk_nullable(variant, at, entries, stack, false, nullable);
                }
            }
            "untagged_union" => {
                Self::leaf(entries, at, shape("untagged_union", BTreeSet::new()));
                for variant in ty.get("variants").and_then(Value::as_array).into_iter().flatten() {
                    self.walk_nullable(variant, at, entries, stack, false, nullable);
                }
            }
            "opaque_json" => Self::leaf(entries, at, shape("json", BTreeSet::new())),
            other => Self::leaf(entries, at, shape(other, BTreeSet::new())),
        }
    }
}

/// One difference that can break a peer on the other side of a version gap.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Break {
    /// Message kind.
    pub message: String,
    /// JSON pointer (empty for a whole message kind).
    pub path: String,
    /// What changed, in words.
    pub why: String,
}

impl std::fmt::Display for Break {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{} {}: {}",
            self.message,
            if self.path.is_empty() { "(whole message)" } else { &self.path },
            self.why
        )
    }
}

/// The breaking differences from `old` to `new`.
pub fn breaking_changes(old: &Surface, new: &Surface) -> Vec<Break> {
    let mut breaks = Vec::new();
    for (kind, old_entries) in old {
        let Some(new_entries) = new.get(kind) else {
            breaks.push(Break {
                message: kind.clone(),
                path: String::new(),
                why: "message removed".into(),
            });
            continue;
        };
        let writer = writer_of(kind);
        for (path, old_shape) in old_entries {
            let push = |breaks: &mut Vec<Break>, why: String| {
                breaks.push(Break { message: kind.clone(), path: path.clone(), why });
            };
            let Some(new_shape) = new_entries.get(path) else {
                push(&mut breaks, "member removed".into());
                continue;
            };
            if old_shape.ty != new_shape.ty {
                push(&mut breaks, format!("type {} -> {}", old_shape.ty, new_shape.ty));
                continue;
            }
            let removed: Vec<_> = old_shape.values.difference(&new_shape.values).cloned().collect();
            if !removed.is_empty() {
                push(&mut breaks, format!("values removed: {}", removed.join(", ")));
            }
            let added: Vec<_> = new_shape.values.difference(&old_shape.values).cloned().collect();
            if writer == Writer::Server && !added.is_empty() && old_shape.ty == "enum" {
                push(
                    &mut breaks,
                    format!("values added (old readers reject them): {}", added.join(", ")),
                );
            }
            match writer {
                Writer::Client if !old_shape.required && new_shape.required => {
                    push(&mut breaks, "became required (old clients omit it)".into());
                }
                Writer::Server if old_shape.required && !new_shape.required => {
                    push(&mut breaks, "became optional (old clients expect it)".into());
                }
                Writer::Server if !old_shape.nullable && new_shape.nullable => {
                    push(&mut breaks, "became nullable (old clients expect a value)".into());
                }
                _ => {}
            }
        }
        if writer == Writer::Client {
            for (path, new_shape) in new_entries {
                let parent_is_new = parent_of(path)
                    .is_some_and(|p| !old_entries.contains_key(p) && new_entries.contains_key(p));
                if new_shape.required && !old_entries.contains_key(path) && !parent_is_new {
                    breaks.push(Break {
                        message: kind.clone(),
                        path: path.clone(),
                        why: "new required member (old clients omit it)".into(),
                    });
                }
            }
        }
    }
    breaks.sort();
    breaks
}

fn parent_of(path: &str) -> Option<&str> {
    path.rfind('/').map(|i| &path[..i]).filter(|p| !p.is_empty())
}

/// True when `rule` handles a break at `path` (same pointer, or an ancestor
/// that the rule moves, renames, removes or retypes as a whole).
fn rule_covers(change: &Change, path: &str) -> bool {
    let mut paths = vec![change.path()];
    if let Change::Move { from, .. } = change {
        paths.push(from);
    }
    if let Change::Rename { path: p, to } = change
        && let Ok(mut tokens) = pointer::parse(p)
    {
        tokens.pop();
        tokens.push(to.clone());
        let renamed = pointer::join(&tokens);
        return [p.as_str(), renamed.as_str()].iter().any(|p| covers_path(p, path, true));
    }
    let whole_subtree = matches!(
        change,
        Change::Move { .. } | Change::Remove { .. } | Change::Retype { .. } | Change::Add { .. }
    );
    paths.iter().any(|p| covers_path(p, path, whole_subtree))
}

fn covers_path(rule_path: &str, path: &str, whole_subtree: bool) -> bool {
    rule_path == path
        || (whole_subtree
            && path.starts_with(rule_path)
            && path[rule_path.len()..].starts_with('/'))
}

/// The breaks that no change in revisions after `since` covers.
pub fn uncovered(breaks: &[Break], schema: &Schema, since: u32) -> Vec<Break> {
    let changes: Vec<_> =
        schema.revisions.iter().filter(|r| r.rev > since).flat_map(|r| &r.changes).collect();
    breaks
        .iter()
        .filter(|b| {
            !changes.iter().any(|c| {
                c.message == b.message && (b.path.is_empty() || rule_covers(&c.change, &b.path))
            })
        })
        .cloned()
        .collect()
}

/// The result of checking a working tree.
#[derive(Debug, PartialEq)]
pub enum Verdict {
    /// The snapshot matches the schema and the compat file.
    Clean,
    /// Breaking changes lack rules; add a revision with rules for these.
    Uncovered(Vec<Break>),
    /// Everything is covered (or additive) but the snapshot is stale; run the
    /// writer to refresh it.
    StaleSnapshot { breaks: Vec<Break> },
}

/// Checks a new surface against the snapshot and the compat schema.
pub fn check(snapshot: &Snapshot, surface: &Surface, schema: &Schema) -> Verdict {
    if &snapshot.surface == surface && snapshot.revision == schema.current() {
        return Verdict::Clean;
    }
    let breaks = breaking_changes(&snapshot.surface, surface);
    let missing = uncovered(&breaks, schema, snapshot.revision);
    if missing.is_empty() { Verdict::StaleSnapshot { breaks } } else { Verdict::Uncovered(missing) }
}
