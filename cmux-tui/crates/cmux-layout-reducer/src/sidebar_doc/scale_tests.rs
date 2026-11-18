//! The sidebar document at scale: what one interaction costs as workspaces,
//! sections and groups grow (Leo, 2026-11-17: "sidebar customization and
//! stress testing it? we should be stress testing everything that isn't
//! already stress tested"). The rule is constant interaction cost: a move,
//! a pin or a drag start costs the rows it touches, not the document.
//!
//! The timing sweep runs only when asked (`CMUX_SIDEBAR_SCALE_BENCH=1`, or a
//! plain `cargo test` whose filter names `scale_bench`) and prints one
//! `SIDEBAR-SCALE-BENCH` JSON line per size and operation.

use std::time::Instant;

use serde_json::{Value, json};

use super::accept::drag_begin;
use super::project::project;
use super::reduce::apply_in_place;
use super::view::{LiveWorkspace, Row, ViewRequest, view};
use super::*;

const S: &str = "mini";

/// One sidebar of `workspaces` live workspaces: `sections` sections (the
/// machine section, Pinned, and custom sections), every section's
/// workspaces in groups of `group_size` (0: loose), and `unplaced` live
/// workspaces with no item yet (they draw at the end of the machine section).
struct Sidebar {
    doc: Doc,
    live: Vec<LiveWorkspace>,
    sections: Vec<SectionId>,
}

fn sidebar(workspaces: usize, sections: usize, group_size: usize, unplaced: usize) -> Sidebar {
    assert!((2..=MAX_SECTIONS).contains(&sections));
    let mut all = vec![Section::machine(S), Section::pinned()];
    for n in 2..sections {
        let mut section = Section::new(&format!("custom{n}"), SectionKind::Custom, Region::Middle);
        section.title = Some(format!("Custom {n}"));
        all.push(section);
    }
    let keys = order_key::spread(all.len());
    for (section, key) in all.iter_mut().zip(keys) {
        section.order = key;
    }
    let ids: Vec<SectionId> = all.iter().map(|s| s.id.clone()).collect();
    let placed = workspaces - unplaced;
    let mut items = Vec::new();
    let mut live = Vec::new();
    // Workspaces dealt round-robin over the sections, in groups.
    let mut per_section: Vec<Vec<usize>> = vec![Vec::new(); ids.len()];
    for n in 0..placed {
        per_section[n % ids.len()].push(n);
    }
    for (section, members) in ids.iter().zip(&per_section) {
        let chunks: Vec<&[usize]> = if group_size == 0 {
            members.iter().map(std::slice::from_ref).collect()
        } else {
            members.chunks(group_size).collect()
        };
        let top_keys = order_key::spread(chunks.len());
        for (chunk, top_key) in chunks.iter().zip(top_keys) {
            let parent = if group_size == 0 {
                None
            } else {
                let id = format!("g-{section}-{}", chunk[0]);
                let body = Body::Group {
                    name: format!("Group {}", chunk[0]),
                    color: None,
                    icon: None,
                    collapsed: false,
                    profile: None,
                };
                let mut group = Item::new(&id, section, body);
                group.order = top_key.clone();
                items.push(group);
                Some(id)
            };
            let member_keys = order_key::spread(chunk.len());
            for (n, key) in chunk.iter().zip(member_keys) {
                let reference = WorkspaceRef::new(S, &format!("w{n}"));
                let mut item = Item::new(
                    &workspace_item_id(&reference),
                    section,
                    Body::Workspace { reference },
                );
                item.parent = parent.clone();
                item.order = if parent.is_some() { key } else { top_key.clone() };
                items.push(item);
            }
        }
    }
    for n in 0..workspaces {
        live.push(LiveWorkspace {
            session_id: S.into(),
            workspace_id: format!("w{n}"),
            title: Some(format!("workspace {n}")),
        });
    }
    Sidebar { doc: Doc::from_parts(1, all, items), live, sections: ids }
}

impl Sidebar {
    fn request(&self) -> ViewRequest {
        ViewRequest { live: self.live.clone(), collapsed: Some(vec![]), ..Default::default() }
    }

    fn rows(&self) -> Vec<Row> {
        view(&self.doc, &self.request())
    }

    /// A placed workspace item near the middle of the document.
    fn middle_item(&self) -> ItemId {
        let placed: Vec<&Item> = self
            .doc
            .items_unordered()
            .filter(|item| matches!(item.body, Body::Workspace { .. }))
            .collect();
        let mut ids: Vec<&str> = placed.iter().map(|item| item.id.as_str()).collect();
        ids.sort_unstable();
        ids[ids.len() / 2].to_string()
    }
}

fn mint() -> impl FnMut() -> ItemId {
    let mut n = 0;
    move || {
        n += 1;
        format!("minted{n}")
    }
}

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_SIDEBAR_SCALE_BENCH").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("scale_bench")) && !args.iter().any(|a| a == "--exact")
}

/// Microseconds per call over `runs` calls: p50, p95, max.
fn time(runs: usize, mut f: impl FnMut()) -> Value {
    let mut samples: Vec<f64> = (0..runs)
        .map(|_| {
            let start = Instant::now();
            f();
            start.elapsed().as_secs_f64() * 1e6
        })
        .collect();
    samples.sort_by(f64::total_cmp);
    let at = |q: f64| {
        let i = ((samples.len() - 1) as f64 * q).round() as usize;
        (samples[i] * 10.0).round() / 10.0
    };
    json!({ "n": runs, "p50_us": at(0.5), "p95_us": at(0.95), "max_us": at(1.0) })
}

fn report(op: &str, shape: &Value, timing: Value) {
    let mut line = json!({ "op": op });
    if let (Some(line), Some(shape), Some(timing)) =
        (line.as_object_mut(), shape.as_object(), timing.as_object())
    {
        line.extend(shape.clone());
        line.extend(timing.clone());
    }
    println!("SIDEBAR-SCALE-BENCH {line}");
}

const SHAPES: &[(usize, usize, usize, usize)] = &[
    // (workspaces, sections, group size, unplaced)
    (20, 2, 0, 0),
    (500, 2, 0, 0),
    (500, 10, 10, 0),
    (500, 64, 10, 0),
    (2000, 10, 10, 0),
    (2000, 64, 100, 0),
    (5000, 64, 10, 0),
    (500, 2, 0, 250),
    (2000, 2, 0, 1000),
];

#[test]
fn scale_bench() {
    if !bench_selected() {
        return;
    }
    for &(workspaces, sections, group_size, unplaced) in SHAPES {
        let mut s = sidebar(workspaces, sections, group_size, unplaced);
        let shape = json!({
            "workspaces": workspaces, "sections": sections, "group": group_size,
            "unplaced": unplaced,
        });
        let runs = if workspaces > 1000 { 40 } else { 200 };
        let request = s.request();
        report("view", &shape, time(runs, || drop(view(&s.doc, &request))));
        let rows = s.rows();
        report("project", &shape, time(runs, || drop(project(&s.doc, &rows))));
        report(
            "rows_json",
            &shape,
            time(runs, || drop(serde_json::to_vec(&rows).expect("rows serialize"))),
        );
        let item = s.middle_item();
        report(
            "drag_begin",
            &shape,
            time(runs, || drop(drag_begin(&s.doc, &rows, std::slice::from_ref(&item)))),
        );
        // One move to the end of another section and back: what a drop costs.
        let home = s.doc.item(&item).expect("item").section.clone();
        let away = s.sections.iter().find(|id| **id != home).expect("two sections").clone();
        let mut mint = mint();
        report(
            "move",
            &shape,
            time(runs, || {
                let to = |section: &str| Op::Move {
                    items: vec![item.clone()],
                    to: Target::end(section),
                };
                apply_in_place(&mut s.doc, &[to(&away)], &mut mint).expect("move away");
                apply_in_place(&mut s.doc, &[to(&home)], &mut mint).expect("move back");
            }),
        );
        report(
            "pin_unpin",
            &shape,
            time(runs, || {
                apply_in_place(&mut s.doc, &[Op::Pin { items: vec![item.clone()] }], &mut mint)
                    .expect("pin");
                apply_in_place(&mut s.doc, &[Op::Unpin { items: vec![item.clone()] }], &mut mint)
                    .expect("unpin");
            }),
        );
    }
}

/// A drag start walks each group tree once, not once per row of it: the
/// subtree walks it does stay within a few times the rows it answers for,
/// whatever the group size (base: a drag in a sidebar of two 1,000-member
/// groups walked about 4 million items, 2.5 ms p50 at 2,000 workspaces in
/// groups of 100).
#[test]
fn a_drag_start_walks_each_group_tree_once() {
    for group_size in [10, 100, 1000] {
        let s = sidebar(2000, 2, group_size, 0);
        let rows = s.rows();
        let item = s.middle_item();
        doc::SUBTREE_VISITS.with(|visits| visits.set(0));
        let table = drag_begin(&s.doc, &rows, std::slice::from_ref(&item));
        let visits = doc::SUBTREE_VISITS.with(std::cell::Cell::get);
        assert_eq!(table.len(), rows.len());
        assert!(
            visits <= 3 * rows.len(),
            "groups of {group_size}: {visits} subtree visits for {} rows",
            rows.len()
        );
    }
}
