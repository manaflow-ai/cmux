//! One sidebar change crosses the FFI in bytes that follow the rows it
//! touches, not the sidebar (Leo: "never ... acceptable ... linear time
//! growth degradation"). At 5,000 workspaces a rename echoed by the daemon,
//! then the window's `project` as the app asks it (no live list when it is
//! the one sent last), crosses a few kilobytes: the renamed block's splice,
//! not the 1 MB projection and the 348 KB live list. The mirror must still
//! show every live row for that request. Counts bytes, not time.

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

/// The request the app sends once its live list is the one it sent last.
fn same_live() -> Vec<u8> {
    br#"{"live_same":true,"collapsed":[]}"#.to_vec()
}

/// Bytes crossing the FFI for one rename (its echo, the request and the
/// answer), and the rows the mirror then shows.
fn tick(workspaces: usize, sections: usize, group_size: usize) -> (usize, usize, usize) {
    let doc = doc(workspaces, sections, group_size);
    let mut ids: Vec<&Item> =
        doc.items_unordered().filter(|item| matches!(item.body, Body::Workspace { .. })).collect();
    ids.sort_by(|a, b| a.id.cmp(&b.id));
    let target = ids[ids.len() / 2].clone();
    let mut mirror = Mirror::new();
    assert_eq!(mirror.load(&serde_json::to_vec(&doc).expect("doc"))["ok"], true);
    let full = request(workspaces);
    let mut first: Value = serde_json::from_slice(&full).expect("request");
    first["fresh"] = json!(true);
    let first = serde_json::to_vec(&first).expect("request");
    let answer = mirror.project_json(&first);
    assert!(!answer.contains("\"error\""), "{}", &answer[..answer.len().min(300)]);
    let shown = mirror.view(&full).as_array().map_or(0, Vec::len);

    let echo = echo(&target, 2);
    assert_eq!(mirror.apply_batch(&echo)["ok"], true);
    let request = same_live();
    let answer = mirror.project_json(&request);
    assert!(!answer.contains("\"error\""), "{}", &answer[..answer.len().min(300)]);
    let after = mirror.view(&same_live()).as_array().map_or(0, Vec::len);
    assert_eq!(after, shown, "a request that sends no live list still shows every live row");
    (request.len() + answer.len(), shown, echo.len())
}

#[test]
fn a_rename_at_5000_workspaces_crosses_the_ffi_in_a_few_kilobytes() {
    for (sections, group_size) in [(64, 10), (2, 0)] {
        let (small, _, _) = tick(500, sections, group_size);
        let (bytes, rows, echo) = tick(5000, sections, group_size);
        let shape = format!("5000 workspaces, {sections} sections, groups of {group_size}");
        assert!(
            bytes <= 8 * 1024 && bytes <= 2 * small + 512,
            "{shape}: one rename crossed {bytes} bytes (echo {echo}) for {rows} rows; at 500: {small}"
        );
    }
}
