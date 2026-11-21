//! One sidebar change costs the rows it touches, not the sidebar (Leo:
//! "never ... acceptable ... linear time growth degradation"). At 5,000
//! workspaces, a rename echoed by the daemon or a one-item move dropped by
//! the person, then the window's `project`, builds a handful of rows: the
//! changed item's top-level block where it left and where it landed, not
//! every row of the document. Counts rows built, not time, so it holds on
//! any runner.

use cmux_layout_reducer::sidebar_doc::view::{LiveWorkspace, ViewRequest, take_rows_built};
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

/// The largest top-level block (a group with its members, or one loose
/// row) plus a section header: what one changed item may rebuild where it
/// left and where it landed.
fn bound(group_size: usize) -> usize {
    2 * (group_size.max(1) + 1) + 4
}

fn check(workspaces: usize, sections: usize, group_size: usize) {
    let shape = format!("{workspaces} workspaces, {sections} sections, groups of {group_size}");
    let doc = doc(workspaces, sections, group_size);
    let mut ids: Vec<&Item> =
        doc.items_unordered().filter(|item| matches!(item.body, Body::Workspace { .. })).collect();
    ids.sort_by(|a, b| a.id.cmp(&b.id));
    let target = ids[ids.len() / 2].clone();
    let away = doc
        .sections()
        .iter()
        .find(|section| section.id != target.section)
        .expect("two sections")
        .id
        .clone();
    let mut mirror = Mirror::new();
    assert_eq!(mirror.load(&serde_json::to_vec(&doc).expect("doc"))["ok"], true);
    let request = request(workspaces);
    let first = mirror.project(&request);
    assert!(first.get("error").is_none(), "{first}");
    let full = take_rows_built();
    assert!(full >= workspaces, "{shape}: the first view builds every row ({full})");

    // A rename the daemon echoes.
    assert_eq!(mirror.apply_batch(&echo(&target, 2))["ok"], true);
    let answer: Value = mirror.project(&request);
    assert!(answer.get("error").is_none(), "{answer}");
    let built = take_rows_built();
    assert!(
        built <= bound(group_size),
        "{shape}: a rename rebuilt {built} rows of {full} (bound {})",
        bound(group_size)
    );

    // A one-item move the person drops, to the end of another section.
    let mv = json!({"idempotency_key": "k-move", "ops": [
        {"op": "move", "items": [target.id], "to": {"section": away}}]});
    let moved = mirror.apply_intent(&serde_json::to_vec(&mv).expect("move"));
    assert_eq!(moved["ok"], true, "{moved}");
    let answer: Value = mirror.project(&request);
    assert!(answer.get("error").is_none(), "{answer}");
    let built = take_rows_built();
    assert!(
        built <= bound(group_size),
        "{shape}: a move rebuilt {built} rows of {full} (bound {})",
        bound(group_size)
    );
}

#[test]
fn a_change_at_5000_workspaces_rebuilds_only_the_rows_it_touches() {
    check(5000, 64, 10);
    check(5000, 2, 0);
}
