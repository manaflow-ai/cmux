//! The incremental view equals the full one: after every op of a long,
//! seeded run of moves, pins, archives, groups, folds, adopts, closes, live
//! changes, filters and section edits, [`ViewCache`]'s rows equal
//! [`view::view`]'s and its projection equals [`project::project`]'s over
//! those rows, on the scale fixtures (loose, grouped, nested, unplaced, a
//! machine with no section yet).

use serde_json::{Value, json};

use super::project::project;
use super::reduce::apply_in_place;
use super::scale_tests::sidebar;
use super::view::{LiveWorkspace, ViewRequest, take_rows_built, view};
use super::view_cache::ViewCache;
use super::view_splice::{Kept, Sent};
use super::*;

/// A small deterministic generator (no dependency).
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }

    fn below(&mut self, n: usize) -> usize {
        if n == 0 { 0 } else { (self.next() % n as u64) as usize }
    }

    fn pick<'a, T>(&mut self, list: &'a [T]) -> Option<&'a T> {
        if list.is_empty() { None } else { Some(&list[self.below(list.len())]) }
    }
}

fn op(value: Value) -> Op {
    serde_json::from_value(value).expect("op")
}

fn ids(doc: &Doc, groups: bool) -> Vec<String> {
    let mut out: Vec<String> = doc
        .items_unordered()
        .filter(|item| item.body.is_group() == groups)
        .map(|item| item.id.clone())
        .collect();
    out.sort();
    out
}

/// One random change: a doc op (refused ones skipped), a live change or a
/// request change.
fn step(
    rng: &mut Rng,
    doc: &mut Doc,
    live: &mut Vec<LiveWorkspace>,
    request: &mut ViewRequest,
    n: usize,
) {
    let items = ids(doc, false);
    let groups = ids(doc, true);
    let sections: Vec<String> = doc.sections().iter().map(|s| s.id.clone()).collect();
    let item = rng.pick(&items).cloned().unwrap_or_default();
    let group = rng.pick(&groups).cloned();
    let section = rng.pick(&sections).cloned().unwrap_or_default();
    let ops = match rng.below(20) {
        0..=3 => vec![op(json!({"op": "move", "items": [item], "to": {"section": section}}))],
        4 => {
            let before = rng.pick(&items).cloned().unwrap_or_default();
            let section = doc.item(&before).map(|i| i.section.clone()).unwrap_or_default();
            let parent = doc.item(&before).and_then(|i| i.parent.clone());
            vec![op(json!({"op": "move", "items": [item],
                "to": {"section": section, "parent": parent, "before": before}}))]
        }
        5 => match group.as_ref().and_then(|g| doc.item(g)) {
            Some(g) => vec![op(json!({"op": "move", "items": [item],
                "to": {"section": g.section, "parent": g.id}}))],
            None => vec![],
        },
        6 => vec![op(json!({"op": "pin", "items": [item]}))],
        7 => vec![op(json!({"op": "unpin", "items": [item]}))],
        8 => vec![op(
            json!({"op": "archive", "items": [rng.pick(&[item.clone(), group.clone().unwrap_or_default()]).cloned()]}),
        )],
        9 => vec![op(json!({"op": "unarchive", "items": [item]}))],
        10 => {
            let other = rng.pick(&items).cloned().unwrap_or_default();
            vec![op(
                json!({"op": "group.create", "id": format!("gnew{n}"), "name": format!("New {n}"),
                "items": [item, other]}),
            )]
        }
        11 => match group {
            Some(g) => vec![op(json!({"op": "group.update", "id": g,
                "patch": {"collapsed": rng.below(2) == 0, "name": format!("Renamed {n}"),
                          "sort": if rng.below(2) == 0 { "name" } else { "manual" }}}))],
            None => vec![],
        },
        12 => match group {
            Some(g) => vec![op(json!({"op": "group.ungroup", "id": g}))],
            None => vec![],
        },
        13 => vec![op(json!({"op": "item.remove", "id": item}))],
        14 => {
            // Adopt a live workspace the document lacks, or a new one.
            let lacking: Vec<&LiveWorkspace> = live
                .iter()
                .filter(|l| {
                    doc.workspace_item(&WorkspaceRef::new(&l.session_id, &l.workspace_id)).is_none()
                })
                .collect();
            match rng.pick(&lacking) {
                Some(l) => vec![op(json!({"op": "adopt",
                    "refs": [{"session_id": l.session_id, "workspace_id": l.workspace_id}]}))],
                None => vec![],
            }
        }
        15 => {
            // A live workspace closes.
            if live.is_empty() {
                return;
            }
            let gone = live.remove(rng.below(live.len()));
            vec![op(json!({"op": "close",
                "refs": [{"session_id": gone.session_id, "workspace_id": gone.workspace_id}]}))]
        }
        16 => {
            // A workspace opens (on this machine, or on one with no section yet).
            let session = if rng.below(3) == 0 { "other" } else { "mini" };
            let at = rng.below(live.len() + 1);
            live.insert(
                at,
                LiveWorkspace {
                    session_id: session.into(),
                    workspace_id: format!("new{n}"),
                    title: Some(format!("new {n}")),
                },
            );
            vec![]
        }
        17 => {
            // The live order changes.
            if live.len() > 1 {
                let a = rng.below(live.len());
                let b = rng.below(live.len());
                live.swap(a, b);
            }
            vec![]
        }
        18 => {
            match rng.below(4) {
                0 => request.filter = Some("1".into()),
                1 => request.filter = None,
                2 => request.collapsed = group.map(|g| vec![g]),
                _ => request.collapsed = Some(vec![]),
            }
            vec![]
        }
        _ => {
            if rng.below(2) == 0 {
                vec![op(json!({"op": "section.update", "id": section,
                    "patch": {"title": format!("Section {n}")}}))]
            } else {
                let mut added =
                    Section::new(&format!("snew{n}"), SectionKind::Custom, Region::Middle);
                added.title = Some(format!("New section {n}"));
                vec![Op::SectionAdd { section: added, place: SectionPlace::default() }]
            }
        }
    };
    let mut minted = 0;
    let mut mint = || {
        minted += 1;
        format!("m{n}_{minted}")
    };
    let _ = apply_in_place(doc, &ops, &mut mint);
}

fn run(seed: u64, steps: usize, workspaces: usize, sections: usize, group: usize, unplaced: usize) {
    let s = sidebar(workspaces, sections, group, unplaced);
    let mut doc = s.doc;
    let mut live = s.live;
    doc.record_touched(true);
    let mut request = ViewRequest { collapsed: Some(vec![]), ..Default::default() };
    let mut cache = ViewCache::default();
    let mut rng = Rng(seed);
    let mut sent = Sent::default();
    let mut kept = Kept::default();
    let mut sent_live: Option<Vec<LiveWorkspace>> = None;
    for n in 0..steps {
        if n > 0 {
            step(&mut rng, &mut doc, &mut live, &mut request, n);
        }
        request.live = live.clone();
        let touched = doc.take_touched();
        // As the app asks: no live list when it is the one last sent.
        let mut asked = request.clone();
        if sent_live.as_ref() == Some(&live) {
            asked.live = Vec::new();
            asked.live_same = true;
        }
        sent_live = Some(live.clone());
        cache.refresh(&doc, asked, touched);
        let rows = view(&doc, &request);
        let answer: Value =
            serde_json::from_str(&cache.answer(&doc, &mut sent, n == 0)).expect("answer");
        kept.apply(&answer);
        assert_eq!(
            kept.projection(),
            serde_json::to_value(project(&doc, &rows)).expect("projection"),
            "seed {seed} step {n}: spliced projection"
        );
        assert_eq!(cache.rows(), rows, "seed {seed} step {n}: rows");
        let full = project(&doc, &rows);
        assert_eq!(
            cache.projection_json(&doc),
            serde_json::to_string(&full).expect("projection"),
            "seed {seed} step {n}: projection bytes"
        );
        assert_eq!(cache.projection(&doc), full, "seed {seed} step {n}: projection");
        // A search rebuilds every time; it lasts one step, so most steps
        // take the incremental path.
        request.filter = None;
    }
}

#[test]
fn the_incremental_view_equals_a_full_view_after_every_op() {
    for seed in 1..=6 {
        run(seed, 300, 60, 4, 5, 6);
        run(seed + 100, 300, 40, 3, 0, 4);
        run(seed + 200, 200, 80, 6, 20, 0);
    }
}

#[test]
fn a_nested_group_and_stored_folds_stay_equal() {
    let s = sidebar(30, 3, 5, 2);
    let mut doc = s.doc;
    doc.record_touched(true);
    let mut request = ViewRequest { live: s.live.clone(), collapsed: None, ..Default::default() };
    let mut cache = ViewCache::default();
    let touched = doc.take_touched();
    cache.refresh(&doc, request.clone(), touched);
    let groups = ids(&doc, true);
    let mut mint = || "x".to_string();
    // Nest one group in another, fold the outer one by its stored flag, archive the inner one.
    let steps = [
        json!({"op": "move", "items": [groups[1]], "to": {"section": doc.item(&groups[0]).unwrap().section, "parent": groups[0]}}),
        json!({"op": "group.update", "id": groups[0], "patch": {"collapsed": true}}),
        json!({"op": "archive", "items": [groups[1]]}),
        json!({"op": "group.update", "id": groups[0], "patch": {"collapsed": false}}),
    ];
    for (n, value) in steps.into_iter().enumerate() {
        apply_in_place(&mut doc, &[op(value)], &mut mint).expect("op applies");
        request.live = s.live.clone();
        let touched = doc.take_touched();
        cache.refresh(&doc, request.clone(), touched);
        let rows = view(&doc, &request);
        assert_eq!(cache.rows(), rows, "step {n}");
        assert_eq!(cache.projection(&doc), project(&doc, &rows), "step {n}");
    }
}

/// The work count: at 5,000 workspaces a one-item move rebuilds the two
/// blocks it touches, whatever the sidebar's size.
#[test]
fn a_move_rebuilds_the_blocks_it_touches_not_the_sidebar() {
    for (workspaces, sections, group) in [(500, 64, 10), (5000, 64, 10), (5000, 2, 0)] {
        let s = sidebar(workspaces, sections, group, 0);
        let mut doc = s.doc;
        doc.record_touched(true);
        let request =
            ViewRequest { live: s.live.clone(), collapsed: Some(vec![]), ..Default::default() };
        let mut cache = ViewCache::default();
        let touched = doc.take_touched();
        cache.refresh(&doc, request.clone(), touched);
        let full = take_rows_built();
        let item = ids(&doc, false)[workspaces / 3].clone();
        let home = doc.item(&item).unwrap().section.clone();
        let away = s.sections.iter().find(|id| **id != home).unwrap().clone();
        let mut mint = || "x".to_string();
        apply_in_place(
            &mut doc,
            &[op(json!({"op": "move", "items": [item], "to": {"section": away}}))],
            &mut mint,
        )
        .expect("move");
        let touched = doc.take_touched();
        cache.refresh(&doc, request.clone(), touched);
        let built = take_rows_built();
        assert!(
            built <= 2 * (group.max(1) + 1),
            "{workspaces}/{sections}/{group}: {built} of {full}"
        );
        assert_eq!(cache.rows(), view(&doc, &request));
        let _ = take_rows_built();
    }
}
