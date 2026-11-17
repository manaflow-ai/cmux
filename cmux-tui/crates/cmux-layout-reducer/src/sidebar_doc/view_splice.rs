//! The projection as splices: what the app holds from the last answer
//! changes only where the kept view's blocks changed, so a rename at 5,000
//! workspaces sends the renamed block, not the 1 MB projection (Leo:
//! "never ... acceptable ... linear time growth degradation").
//!
//! Every list of [`project::Projection`] is a run of segments, one per
//! block (or a section's unplaced rows), each named by the block's build
//! id ([`view_cache::Block::version`]). The mirror remembers the segments
//! it last sent ([`Sent`]); an answer names, per list, the element ranges
//! to replace (`{"at", "remove", "insert"}`, applied in order), and the
//! small fields (the section shapes, the machine maps, the group settings)
//! only when their JSON changed:
//!
//! ```json
//! {"reset": true?, "items": [splice], "archived": [..], "band_groups": [..],
//!  "unplaced": [..], "machines": {"<session>": [..]}, "bands": {"<section>": [..]},
//!  "fields": {"sections": [{"type": "workspaces", "like"?} | {"type": "band", "section"}],
//!             "machine_sections", "machine_order", "host_groups", "group_sorts",
//!             "pinned_in_group", "group_row_limits", "group_revealed"}}
//! ```
//!
//! A band section's `items` are its `bands` list; `machines` holds the
//! sessions whose list is not empty. `Kept` (tests only) applies answers the way the
//! app does; the tests hold its projection equal to [`project::project`].

use std::collections::{BTreeMap, HashMap};
use std::fmt::Write;

use serde::Serialize;
#[cfg(test)]
use serde_json::{Map, Value};

use super::doc::Doc;
use super::model::*;
use super::view_cache::{Part, SectionView, ViewCache};

/// One part's list elements as JSON (made once per block build).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PartJson {
    nodes: Vec<String>,
    band_items: Vec<String>,
    band_groups: Vec<String>,
    items: Vec<String>,
    archived: Vec<String>,
}

fn texts<T: Serialize>(list: &[T]) -> Vec<String> {
    list.iter().map(|value| serde_json::to_string(value).unwrap_or_default()).collect()
}

impl PartJson {
    fn of(part: &Part) -> Self {
        PartJson {
            nodes: texts(&part.nodes),
            band_items: texts(&part.band_items),
            band_groups: texts(&part.band_groups),
            items: texts(&part.items),
            archived: texts(&part.archived),
        }
    }
}

/// What the caller holds of the last answers: each list's segments (build
/// id, element count) and each field's JSON.
#[derive(Debug, Clone, Default)]
pub struct Sent {
    lists: HashMap<String, Vec<(u64, usize)>>,
    fields: HashMap<&'static str, String>,
}

#[derive(Clone, Copy)]
enum Kind {
    Nodes,
    BandItems,
    BandGroups,
    Items,
    Archived,
}

enum Source<'a> {
    Part(&'a Part, Kind),
    Unplaced(&'a SectionView),
}

struct Segment<'a> {
    id: u64,
    len: usize,
    source: Source<'a>,
}

impl Segment<'_> {
    fn write_elements(&self, out: &mut String, first: &mut bool) {
        let mut put = |text: &str| {
            if !*first {
                out.push(',');
            }
            *first = false;
            out.push_str(text);
        };
        match &self.source {
            Source::Part(part, kind) => {
                let json = part.json.get_or_init(|| PartJson::of(part));
                let list = match kind {
                    Kind::Nodes => &json.nodes,
                    Kind::BandItems => &json.band_items,
                    Kind::BandGroups => &json.band_groups,
                    Kind::Items => &json.items,
                    Kind::Archived => &json.archived,
                };
                for text in list {
                    put(text);
                }
            }
            Source::Unplaced(view) => {
                for reference in view.unplaced.iter().filter_map(|(_, row)| row.reference.as_ref())
                {
                    put(&serde_json::to_string(reference).unwrap_or_default());
                }
            }
        }
    }
}

/// A section's shape in `fields.sections` (its items are a `bands` list).
#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Shape<'a> {
    Workspaces {
        #[serde(skip_serializing_if = "Option::is_none")]
        like: Option<&'a Section>,
    },
    Band {
        section: &'a Section,
    },
}

fn part_len(part: &Part, kind: Kind) -> usize {
    match kind {
        Kind::Nodes => part.nodes.len(),
        Kind::BandItems => part.band_items.len(),
        Kind::BandGroups => part.band_groups.len(),
        Kind::Items => part.items.len(),
        Kind::Archived => part.archived.len(),
    }
}

/// The longest run of `seq` that increases, as indexes into `seq`.
fn increasing_run(seq: &[usize]) -> Vec<usize> {
    // The smallest (value, index) ending a run of each length, and each
    // element's predecessor in its run.
    let mut tails: Vec<(usize, usize)> = Vec::new();
    let mut before: Vec<Option<usize>> = Vec::with_capacity(seq.len());
    for (index, &value) in seq.iter().enumerate() {
        let at = tails.partition_point(|&(tail, _)| tail < value);
        before.push(at.checked_sub(1).and_then(|prior| tails.get(prior)).map(|&(_, i)| i));
        match tails.get_mut(at) {
            Some(slot) => *slot = (value, index),
            None => tails.push((value, index)),
        }
    }
    let mut run = Vec::with_capacity(tails.len());
    let mut next = tails.last().map(|&(_, index)| index);
    while let Some(index) = next {
        run.push(index);
        next = before.get(index).copied().flatten();
    }
    run.reverse();
    run
}

/// `list[range]`, empty when the range does not fit.
fn span<T>(list: &[T], range: std::ops::Range<usize>) -> &[T] {
    list.get(range).unwrap_or(&[])
}

/// The splices that turn `old` into `new`: (element offset, elements
/// removed, the new segments inserted), applied in order.
fn splices(
    old: &[(u64, usize)],
    new: &[Segment<'_>],
) -> Vec<(usize, usize, std::ops::Range<usize>)> {
    let prefix = old.iter().zip(new).take_while(|(o, n)| o.0 == n.id).count();
    let suffix = span(old, prefix..old.len())
        .iter()
        .rev()
        .zip(span(new, prefix..new.len()).iter().rev())
        .take_while(|(o, n)| o.0 == n.id)
        .count();
    let old_mid = span(old, prefix..old.len().saturating_sub(suffix));
    let new_mid = span(new, prefix..new.len().saturating_sub(suffix));
    if old_mid.is_empty() && new_mid.is_empty() {
        return Vec::new();
    }
    let at_old: HashMap<u64, usize> =
        old_mid.iter().enumerate().map(|(index, (id, _))| (*id, index)).collect();
    // New segments the caller already holds, with their old place.
    let held: Vec<(usize, usize)> = new_mid
        .iter()
        .enumerate()
        .filter_map(|(index, segment)| at_old.get(&segment.id).map(|&old| (index, old)))
        .collect();
    let olds: Vec<usize> = held.iter().map(|(_, old)| *old).collect();
    let mut stable: Vec<(usize, usize)> =
        increasing_run(&olds).into_iter().filter_map(|index| held.get(index).copied()).collect();
    stable.push((new_mid.len(), old_mid.len()));
    let mut out = Vec::new();
    let mut offset: usize = span(new, 0..prefix).iter().map(|segment| segment.len).sum();
    let (mut next_new, mut next_old) = (0, 0);
    for (stable_new, stable_old) in stable {
        let removed: usize = span(old_mid, next_old..stable_old).iter().map(|(_, len)| len).sum();
        if removed > 0 || next_new < stable_new {
            out.push((offset, removed, prefix + next_new..prefix + stable_new));
        }
        offset +=
            span(new_mid, next_new..stable_new).iter().map(|segment| segment.len).sum::<usize>();
        if let Some(segment) = new_mid.get(stable_new) {
            offset += segment.len;
        }
        (next_new, next_old) = (stable_new + 1, stable_old + 1);
    }
    out
}

impl ViewCache {
    /// The answer to the caller holding `sent` (nothing, when `fresh`), as
    /// splices of the projection [`ViewCache::projection_json`] answers in
    /// full; `sent` becomes what the caller holds after applying it.
    pub fn answer(&self, doc: &Doc, sent: &mut Sent, fresh: bool) -> String {
        if fresh {
            *sent = Sent::default();
        }
        let mut lists: BTreeMap<String, Vec<Segment<'_>>> = BTreeMap::new();
        for name in ["items", "archived", "band_groups", "unplaced"] {
            lists.insert(name.to_string(), Vec::new());
        }
        fn push<'a>(
            lists: &mut BTreeMap<String, Vec<Segment<'a>>>,
            name: &str,
            id: u64,
            len: usize,
            source: Source<'a>,
        ) {
            if len > 0 {
                lists.entry(name.to_string()).or_default().push(Segment { id, len, source });
            }
        }
        let mut shapes: Vec<Shape<'_>> = Vec::new();
        let mut machine_sections: BTreeMap<&str, &SectionId> = BTreeMap::new();
        let mut machine_order: Vec<&SectionId> = Vec::new();
        let mut placed_list = false;
        for view in self.sections() {
            if !view.draws() {
                continue;
            }
            let body = !view.folded();
            let section = doc.section(&view.section.id).unwrap_or(&view.section);
            let blocks = view.blocks.iter().filter(|_| body);
            for block in blocks.clone() {
                let part = &block.part;
                for (name, kind) in [("items", Kind::Items), ("archived", Kind::Archived)] {
                    push(
                        &mut lists,
                        name,
                        block.version,
                        part_len(part, kind),
                        Source::Part(part, kind),
                    );
                }
            }
            if let Some(session) = section.kind.machine() {
                if !machine_sections.contains_key(session) {
                    machine_order.push(&section.id);
                }
                machine_sections.insert(session, &section.id);
                if !placed_list {
                    placed_list = true;
                    shapes.push(Shape::Workspaces { like: Some(section) });
                }
                let name = format!("machines/{session}");
                for block in blocks {
                    let part = &block.part;
                    let len = part_len(part, Kind::Nodes);
                    push(&mut lists, &name, block.version, len, Source::Part(part, Kind::Nodes));
                }
                if body {
                    push(
                        &mut lists,
                        "unplaced",
                        view.unplaced_version,
                        view.unplaced.len(),
                        Source::Unplaced(view),
                    );
                }
                continue;
            }
            let name = format!("bands/{}", section.id);
            lists.entry(name.clone()).or_default();
            for block in blocks {
                let part = &block.part;
                let len = part_len(part, Kind::BandItems);
                push(&mut lists, &name, block.version, len, Source::Part(part, Kind::BandItems));
                let len = part_len(part, Kind::BandGroups);
                push(
                    &mut lists,
                    "band_groups",
                    block.version,
                    len,
                    Source::Part(part, Kind::BandGroups),
                );
            }
            shapes.push(Shape::Band { section });
        }
        if !placed_list {
            shapes.push(Shape::Workspaces { like: None });
        }

        let mut out = String::from("{");
        if fresh {
            out.push_str("\"reset\":true,");
        }
        // Per list: its splices, grouped as the wire nests them.
        let mut groups: BTreeMap<&str, Vec<(String, String)>> = BTreeMap::new();
        let mut write_list = |name: &str, text: String| {
            let (group, key) = match name.split_once('/') {
                Some((group, key)) => (group, key.to_string()),
                None => (name, String::new()),
            };
            let group: &'static str = match group {
                "machines" => "machines",
                "bands" => "bands",
                "items" => "items",
                "archived" => "archived",
                "band_groups" => "band_groups",
                _ => "unplaced",
            };
            groups.entry(group).or_default().push((key, text));
        };
        let gone: Vec<String> =
            sent.lists.keys().filter(|name| !lists.contains_key(*name)).cloned().collect();
        for name in gone {
            let held = sent.lists.remove(&name).unwrap_or_default();
            let total: usize = held.iter().map(|(_, len)| len).sum();
            if total > 0 {
                write_list(&name, format!("[{{\"at\":0,\"remove\":{total},\"insert\":[]}}]"));
            }
        }
        for (name, segments) in &lists {
            let held = sent.lists.get(name).map_or(&[][..], Vec::as_slice);
            let changes = splices(held, segments);
            if changes.is_empty() && sent.lists.contains_key(name) {
                continue;
            }
            let mut text = String::from("[");
            for (index, (at, remove, range)) in changes.iter().enumerate() {
                if index > 0 {
                    text.push(',');
                }
                let _ = write!(text, "{{\"at\":{at},\"remove\":{remove},\"insert\":[");
                let mut first = true;
                for segment in span(segments, range.clone()) {
                    segment.write_elements(&mut text, &mut first);
                }
                text.push_str("]}");
            }
            text.push(']');
            write_list(name, text);
            sent.lists.insert(name.clone(), segments.iter().map(|s| (s.id, s.len)).collect());
        }
        for (group, entries) in groups {
            let _ = write!(out, "\"{group}\":");
            if matches!(group, "machines" | "bands") {
                out.push('{');
                for (index, (key, text)) in entries.iter().enumerate() {
                    if index > 0 {
                        out.push(',');
                    }
                    out.push_str(&serde_json::to_string(key).unwrap_or_default());
                    out.push(':');
                    out.push_str(text);
                }
                out.push('}');
            } else if let Some((_, text)) = entries.first() {
                out.push_str(text);
            }
            out.push(',');
        }

        let settings = self.settings();
        let fields: [(&'static str, String); 8] = [
            ("sections", serde_json::to_string(&shapes).unwrap_or_default()),
            ("machine_sections", serde_json::to_string(&machine_sections).unwrap_or_default()),
            ("machine_order", serde_json::to_string(&machine_order).unwrap_or_default()),
            ("host_groups", serde_json::to_string(self.host_groups()).unwrap_or_default()),
            ("group_sorts", serde_json::to_string(&settings.sorts).unwrap_or_default()),
            (
                "pinned_in_group",
                serde_json::to_string(&settings.pinned_in_group).unwrap_or_default(),
            ),
            ("group_row_limits", serde_json::to_string(&settings.row_limits).unwrap_or_default()),
            ("group_revealed", serde_json::to_string(&settings.revealed).unwrap_or_default()),
        ];
        out.push_str("\"fields\":{");
        let mut first = true;
        for (name, text) in fields {
            if sent.fields.get(name) == Some(&text) {
                continue;
            }
            if !first {
                out.push(',');
            }
            first = false;
            let _ = write!(out, "\"{name}\":{text}");
            sent.fields.insert(name, text);
        }
        out.push_str("}}");
        out
    }
}

/// What the app keeps from the answers, applied the way it applies them:
/// the reference the tests hold to [`project::project`] (the app has its own,
/// `SidebarDocWire.KeptProjection`).
#[cfg(test)]
#[derive(Debug, Clone, Default)]
pub struct Kept {
    lists: BTreeMap<String, Vec<Value>>,
    fields: Map<String, Value>,
}

#[cfg(test)]
impl Kept {
    /// Apply one answer.
    pub fn apply(&mut self, answer: &Value) {
        if answer["reset"] == true {
            *self = Kept::default();
        }
        let mut splice = |name: String, list: &Value| {
            let held = self.lists.entry(name).or_default();
            for change in list.as_array().into_iter().flatten() {
                let at = change["at"].as_u64().unwrap_or(0) as usize;
                let remove = change["remove"].as_u64().unwrap_or(0) as usize;
                let insert = change["insert"].as_array().cloned().unwrap_or_default();
                held.splice(at..at + remove, insert);
            }
        };
        for name in ["items", "archived", "band_groups", "unplaced"] {
            if let Some(list) = answer.get(name) {
                splice(name.to_string(), list);
            }
        }
        for group in ["machines", "bands"] {
            for (key, list) in answer[group].as_object().into_iter().flatten() {
                splice(format!("{group}/{key}"), list);
            }
        }
        for (name, value) in answer["fields"].as_object().into_iter().flatten() {
            self.fields.insert(name.clone(), value.clone());
        }
    }

    /// The projection it holds, in [`project::Projection`]'s wire form.
    pub fn projection(&self) -> Value {
        let list = |name: &str| Value::Array(self.lists.get(name).cloned().unwrap_or_default());
        let mut sections = Vec::new();
        for shape in self.fields.get("sections").and_then(Value::as_array).into_iter().flatten() {
            let mut shape = shape.clone();
            if shape["type"] == "band" {
                let id = shape["section"]["id"].as_str().unwrap_or_default().to_string();
                shape["items"] = list(&format!("bands/{id}"));
            }
            sections.push(shape);
        }
        let mut machines = Map::new();
        for (name, nodes) in &self.lists {
            if let Some(session) = name.strip_prefix("machines/")
                && !nodes.is_empty()
            {
                machines.insert(session.to_string(), Value::Array(nodes.clone()));
            }
        }
        let mut out = Map::new();
        out.insert("sections".into(), Value::Array(sections));
        out.insert("machines".into(), Value::Object(machines));
        for name in ["items", "unplaced", "band_groups", "archived"] {
            out.insert(name.into(), list(name));
        }
        for (name, value) in &self.fields {
            let empty_map = value.as_object().is_some_and(Map::is_empty);
            if name == "sections"
                || (matches!(name.as_str(), "group_row_limits" | "group_revealed") && empty_map)
            {
                continue;
            }
            out.insert(name.clone(), value.clone());
        }
        Value::Object(out)
    }
}
