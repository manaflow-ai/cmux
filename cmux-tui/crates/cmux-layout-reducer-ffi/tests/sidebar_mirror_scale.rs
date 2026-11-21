//! The sidebar mirror at scale: what the app pays per sidebar change as
//! workspaces grow (Leo, 2026-11-17: "we should be stress testing everything
//! that isn't already stress tested"). One tick is what a daemon change costs
//! the app: `apply_batch` with one echoed item row, then `project` with the
//! window's view request (every live workspace), its answer serialized as
//! the FFI hands it over. A drag start is `drag_begin` on the kept rows.
//!
//! The sweep runs only when asked (`CMUX_SIDEBAR_SCALE_BENCH=1`, or a plain
//! `cargo test` whose filter names `scale_bench`) and prints one
//! `SIDEBAR-MIRROR-SCALE-BENCH` JSON line per size and step.

use std::time::Instant;

use cmux_layout_reducer::sidebar_doc::view::{LiveWorkspace, ViewRequest};
use cmux_layout_reducer::sidebar_doc::*;
use cmux_layout_reducer_ffi::sidebar_mirror::Mirror;
use serde_json::{Value, json};

const S: &str = "mini";

/// `workspaces` workspaces over `sections` sections (machine, Pinned,
/// custom), in groups of `group_size` (0: loose).
fn doc(workspaces: usize, sections: usize, group_size: usize) -> Doc {
    let mut all = vec![Section::machine(S), Section::pinned()];
    for n in 2..sections {
        let mut section = Section::new(&format!("custom{n}"), SectionKind::Custom, Region::Middle);
        section.title = Some(format!("Custom {n}"));
        all.push(section);
    }
    for (section, key) in all.iter_mut().zip(order_key::spread(sections)) {
        section.order = key;
    }
    let ids: Vec<SectionId> = all.iter().map(|s| s.id.clone()).collect();
    let mut per_section: Vec<Vec<usize>> = vec![Vec::new(); ids.len()];
    for n in 0..workspaces {
        per_section[n % ids.len()].push(n);
    }
    let mut items = Vec::new();
    for (section, members) in ids.iter().zip(&per_section) {
        let chunks: Vec<&[usize]> = if group_size == 0 {
            members.iter().map(std::slice::from_ref).collect()
        } else {
            members.chunks(group_size).collect()
        };
        for (chunk, top_key) in chunks.iter().zip(order_key::spread(chunks.len())) {
            let parent = (group_size > 0).then(|| {
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
                id
            });
            for (n, key) in chunk.iter().zip(order_key::spread(chunk.len())) {
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
    Doc::from_parts(1, all, items)
}

fn request(workspaces: usize) -> Vec<u8> {
    let live: Vec<LiveWorkspace> = (0..workspaces)
        .map(|n| LiveWorkspace {
            session_id: S.into(),
            workspace_id: format!("w{n}"),
            title: Some(format!("workspace {n}")),
        })
        .collect();
    serde_json::to_vec(&ViewRequest { live, collapsed: Some(vec![]), ..Default::default() })
        .expect("request")
}

/// The echo of one item row at `revision`: a renamed workspace.
fn echo(item: &Item, revision: u64) -> Vec<u8> {
    let mut item = item.clone();
    item.extra.insert("label".into(), json!(format!("renamed {revision}")));
    serde_json::to_vec(&json!({
        "changes": [
            {"resource": "sidebar_doc", "value": {
                "revision": revision.to_string(), "previous_revision": (revision - 1).to_string()}},
            {"kind": "state_upsert", "resource": "sidebar_item", "id": item.id, "value": item},
        ]
    }))
    .expect("echo")
}

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_SIDEBAR_SCALE_BENCH").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("scale_bench")) && !args.iter().any(|a| a == "--exact")
}

/// Microseconds: p50, p95, max.
fn summary(mut samples: Vec<f64>) -> Value {
    samples.sort_by(f64::total_cmp);
    let at = |q: f64| {
        let i = ((samples.len() - 1) as f64 * q).round() as usize;
        (samples[i] * 10.0).round() / 10.0
    };
    json!({ "n": samples.len(), "p50_us": at(0.5), "p95_us": at(0.95), "max_us": at(1.0) })
}

fn report(step: &str, shape: &Value, timing: Value, extra: Value) {
    let mut line = json!({ "step": step });
    for part in [shape, &timing, &extra] {
        if let (Some(line), Some(part)) = (line.as_object_mut(), part.as_object()) {
            line.extend(part.clone());
        }
    }
    println!("SIDEBAR-MIRROR-SCALE-BENCH {line}");
}

const SHAPES: &[(usize, usize, usize)] =
    &[(20, 2, 0), (500, 2, 0), (500, 64, 10), (2000, 10, 10), (5000, 64, 10), (2000, 2, 2000)];

#[test]
fn sidebar_mirror_scale_bench() {
    if !bench_selected() {
        return;
    }
    for &(workspaces, sections, group_size) in SHAPES {
        let shape = json!({ "workspaces": workspaces, "sections": sections, "group": group_size });
        let doc = doc(workspaces, sections, group_size);
        let target = doc
            .items_unordered()
            .find(|item| matches!(item.body, Body::Workspace { .. }))
            .expect("a workspace")
            .clone();
        let doc_bytes = serde_json::to_vec(&doc).expect("doc");
        let mut mirror = Mirror::new();
        let start = Instant::now();
        let loaded = mirror.load(&doc_bytes);
        let load_us = start.elapsed().as_secs_f64() * 1e6;
        assert_eq!(loaded["ok"], true, "{loaded}");
        report("load", &shape, json!({ "us": load_us }), json!({ "doc_bytes": doc_bytes.len() }));
        // The first ask sends the live list (and holds nothing); every tick
        // after it asks as the app does: the same live list, not sent again.
        let first = request(workspaces);
        let mut fresh: Value = serde_json::from_slice(&first).expect("request");
        fresh["fresh"] = json!(true);
        drop(mirror.project_json(&serde_json::to_vec(&fresh).expect("request")));
        let request = br#"{"live_same":true,"collapsed":[]}"#.to_vec();
        let runs = if workspaces > 1000 { 40 } else { 200 };
        let (mut batch, mut project, mut tick) = (Vec::new(), Vec::new(), Vec::new());
        let mut answer_bytes = 0;
        for n in 0..runs {
            let echo = echo(&target, 2 + n as u64);
            let started = Instant::now();
            let answer = mirror.apply_batch(&echo);
            let batched = started.elapsed();
            assert_eq!(answer["ok"], true, "{answer}");
            let projected = Instant::now();
            // What the FFI entry hands over (`cmux_sidebar_mirror_project`).
            let answer = mirror.project_json(&request);
            project.push(projected.elapsed().as_secs_f64() * 1e6);
            batch.push(batched.as_secs_f64() * 1e6);
            tick.push(started.elapsed().as_secs_f64() * 1e6);
            answer_bytes = answer.len();
        }
        report("apply_batch", &shape, summary(batch), json!({}));
        report(
            "project",
            &shape,
            summary(project),
            json!({ "request_bytes": request.len(), "answer_bytes": answer_bytes }),
        );
        report("tick", &shape, summary(tick), json!({}));
        let drag = serde_json::to_vec(&json!({ "items": [target.id] })).expect("drag");
        let mut samples = Vec::new();
        for _ in 0..runs {
            let started = Instant::now();
            let table = serde_json::to_vec(&mirror.drag_begin(&drag)).expect("table");
            samples.push(started.elapsed().as_secs_f64() * 1e6);
            assert!(table.len() > 2);
        }
        report("drag_begin", &shape, summary(samples), json!({}));
    }
}
