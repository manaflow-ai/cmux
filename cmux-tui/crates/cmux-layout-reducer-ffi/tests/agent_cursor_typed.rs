//! `cmux_agent_cursor_visibility`, the typed call the app makes per agent
//! input event and per motion frame: every case of
//! schemas/agent-cursor-visibility/vectors.json, with its ids numbered as the
//! app numbers them, answers its `expect`, the same as the JSON operation;
//! the structs have the header's layout; bad input is refused.

use cmux_focus_core::agent_cursor_visibility::{
    Anchor, NotDrawnReason, Rect, Snapshot, Visibility, resolve,
};
use cmux_layout_reducer_ffi::agent_cursor::*;
use cmux_layout_reducer_ffi::focus::NONE;
use cmux_layout_reducer_ffi::{ERR_INVALID, ERR_NULL, OK};
use serde_json::Value;
use std::collections::HashMap;
use std::mem::size_of;

const VECTORS: &str = include_str!("../../../../schemas/agent-cursor-visibility/vectors.json");

/// A snapshot as the app sends it: numbered ids and flat arrays.
#[derive(Default)]
struct Flat {
    numbers: HashMap<String, u32>,
    names: Vec<String>,
    windows: Vec<CmuxCursorWindow>,
    ids: Vec<u32>,
    rows: Vec<CmuxCursorKeyedRect>,
    panes: Vec<CmuxCursorPane>,
    chips: Vec<CmuxCursorKeyedRect>,
}

impl Flat {
    fn number(&mut self, id: &str) -> u32 {
        if let Some(&number) = self.numbers.get(id) {
            return number;
        }
        let number = self.names.len() as u32;
        self.numbers.insert(id.to_owned(), number);
        self.names.push(id.to_owned());
        number
    }

    fn optional(&mut self, id: Option<&String>) -> u32 {
        id.map_or(NONE, |id| self.number(id))
    }

    fn keyed(&mut self, map: &HashMap<String, Rect>) -> Vec<CmuxCursorKeyedRect> {
        let mut keys: Vec<&String> = map.keys().collect();
        keys.sort();
        keys.into_iter()
            .map(|key| CmuxCursorKeyedRect { key: self.number(key), reserved: 0, rect: map[key] })
            .collect()
    }

    fn build(target: &str, snapshot: &Snapshot) -> (Flat, u32, u32, u32) {
        let mut flat = Flat::default();
        let target = flat.number(target);
        let (tab_workspace, tab_pane) = match &snapshot.tab {
            Some(tab) => (flat.number(&tab.workspace), flat.number(&tab.pane)),
            None => (NONE, NONE),
        };
        for window in &snapshot.windows {
            let listed_offset = flat.ids.len() as u32;
            for workspace in &window.listed_workspaces {
                let number = flat.number(workspace);
                flat.ids.push(number);
            }
            let rows = flat.keyed(&window.sidebar_rows);
            let rows_offset = flat.rows.len() as u32;
            flat.rows.extend(&rows);
            let panes_offset = flat.panes.len() as u32;
            for pane in &window.panes {
                let chips = flat.keyed(&pane.chips);
                let chips_offset = flat.chips.len() as u32;
                flat.chips.extend(&chips);
                let mut flags = 0;
                let mut take = |rect: Option<Rect>, bit: u32| {
                    rect.map_or_else(Rect::default, |rect| {
                        flags |= bit;
                        rect
                    })
                };
                let frame = take(pane.frame, PANE_HAS_FRAME);
                let clip = take(pane.clip, PANE_HAS_CLIP);
                let strip = take(pane.strip, PANE_HAS_STRIP);
                let viewport = take(pane.page.map(|page| page.viewport), PANE_HAS_PAGE);
                let (zoom, scale) = match pane.page {
                    Some(page) => {
                        if page.scale.is_some() {
                            flags |= PANE_HAS_SCALE;
                        }
                        (page.zoom, page.scale.unwrap_or(0.0))
                    }
                    None => (0.0, 0.0),
                };
                let record = CmuxCursorPane {
                    id: flat.number(&pane.id),
                    selected_tab: flat.optional(pane.selected_tab.as_ref()),
                    flags,
                    chips_offset,
                    chips_count: chips.len() as u32,
                    reserved: 0,
                    frame,
                    clip,
                    strip,
                    viewport,
                    zoom,
                    scale,
                };
                flat.panes.push(record);
            }
            let mut flags = 0;
            if window.minimized {
                flags |= WINDOW_MINIMIZED;
            }
            if window.on_active_space {
                flags |= WINDOW_ON_ACTIVE_SPACE;
            }
            if window.sidebar_hidden {
                flags |= WINDOW_SIDEBAR_HIDDEN;
            }
            let record = CmuxCursorWindow {
                id: flat.number(&window.id),
                shown_workspace: flat.optional(window.shown_workspace.as_ref()),
                flags,
                listed_offset,
                listed_count: window.listed_workspaces.len() as u32,
                rows_offset,
                rows_count: rows.len() as u32,
                panes_offset,
                panes_count: window.panes.len() as u32,
                reserved: 0,
                overlay: window.overlay,
            };
            flat.windows.push(record);
        }
        (flat, target, tab_workspace, tab_pane)
    }

    fn snapshot(&self, target: u32, tab_workspace: u32, tab_pane: u32) -> CmuxCursorSnapshot {
        CmuxCursorSnapshot {
            target,
            tab_workspace,
            tab_pane,
            reserved: 0,
            windows: self.windows.as_ptr(),
            windows_count: self.windows.len(),
            ids: self.ids.as_ptr(),
            ids_count: self.ids.len(),
            rows: self.rows.as_ptr(),
            rows_count: self.rows.len(),
            panes: self.panes.as_ptr(),
            panes_count: self.panes.len(),
            chips: self.chips.as_ptr(),
            chips_count: self.chips.len(),
        }
    }

    /// The typed answer in the JSON operation's shape.
    fn visibility(&self, answer: &CmuxCursorVisibility) -> Visibility {
        let anchors = [
            "tabChip",
            "tabStrip",
            "columnEdge.leading",
            "columnEdge.trailing",
            "columnEdge.top",
            "columnEdge.bottom",
            "workspaceRow",
            "windowEdge",
        ];
        let reasons = [
            NotDrawnReason::TabClosed,
            NotDrawnReason::NotInAnyWindow,
            NotDrawnReason::Minimized,
            NotDrawnReason::OtherSpace,
        ];
        let window = || self.names[answer.window as usize].clone();
        match answer.kind {
            KIND_VISIBLE => Visibility::Visible {
                window: window(),
                viewport: answer.viewport,
                clip: answer.clip,
                zoom: answer.zoom,
                scale: answer.scale,
            },
            KIND_HIDDEN => Visibility::Hidden {
                window: window(),
                anchor: Anchor::parse(anchors[answer.anchor as usize]).unwrap(),
                rect: answer.rect,
            },
            KIND_NOT_DRAWN => Visibility::NotDrawn { reason: reasons[answer.reason as usize] },
            other => panic!("unknown kind {other}"),
        }
    }
}

fn call(snapshot: &CmuxCursorSnapshot) -> (i32, CmuxCursorVisibility) {
    let mut out = CmuxCursorVisibility::default();
    let code = unsafe { cmux_agent_cursor_visibility(snapshot, &mut out) };
    (code, out)
}

fn typed(target: &str, snapshot: &Snapshot) -> Visibility {
    let (flat, target, workspace, pane) = Flat::build(target, snapshot);
    let (code, out) = call(&flat.snapshot(target, workspace, pane));
    assert_eq!(code, OK);
    flat.visibility(&out)
}

fn cases() -> Vec<(String, String, Snapshot, Visibility)> {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    vectors["cases"]
        .as_array()
        .unwrap()
        .iter()
        .map(|case| {
            (
                case["name"].as_str().unwrap().to_owned(),
                case["target"].as_str().unwrap().to_owned(),
                serde_json::from_value(case["snapshot"].clone()).unwrap(),
                serde_json::from_value(case["expect"].clone()).unwrap(),
            )
        })
        .collect()
}

#[test]
fn agent_cursor_typed_every_vector_answers_its_expect() {
    let cases = cases();
    assert!(cases.len() >= 26);
    for (name, target, snapshot, expect) in cases {
        assert_eq!(typed(&target, &snapshot), expect, "{name}");
    }
}

/// The typed call and the JSON rules agree beyond the vectors: every vector
/// with each of its windows, panes and chips in turn taken away.
#[test]
fn agent_cursor_typed_agrees_with_the_json_rules_on_variants() {
    let mut checked = 0;
    for (name, target, snapshot, _) in cases() {
        let mut variants = vec![snapshot.clone()];
        for w in 0..snapshot.windows.len() {
            let mut without = snapshot.clone();
            without.windows.remove(w);
            variants.push(without);
            for p in 0..snapshot.windows[w].panes.len() {
                let mut chipless = snapshot.clone();
                chipless.windows[w].panes[p].chips.clear();
                variants.push(chipless);
                let mut pageless = snapshot.clone();
                pageless.windows[w].panes[p].page = None;
                variants.push(pageless);
            }
        }
        for variant in variants {
            assert_eq!(typed(&target, &variant), resolve(&target, &variant), "{name}");
            checked += 1;
        }
    }
    assert!(checked > 26, "{checked} variants");
}

/// The layout the C header declares.
#[test]
fn agent_cursor_typed_structs_have_the_header_layout() {
    assert_eq!(size_of::<Rect>(), 32);
    assert_eq!(size_of::<CmuxCursorKeyedRect>(), 40);
    assert_eq!(size_of::<CmuxCursorWindow>(), 72);
    assert_eq!(size_of::<CmuxCursorPane>(), 168);
    assert_eq!(size_of::<CmuxCursorSnapshot>(), 96);
    assert_eq!(size_of::<CmuxCursorVisibility>(), 128);
}

#[test]
fn agent_cursor_typed_refuses_bad_input() {
    let (_, target, snapshot, _) = cases().into_iter().next().unwrap();
    let (flat, target, workspace, pane) = Flat::build(&target, &snapshot);
    let good = flat.snapshot(target, workspace, pane);

    let mut out = CmuxCursorVisibility::default();
    assert_eq!(unsafe { cmux_agent_cursor_visibility(std::ptr::null(), &mut out) }, ERR_NULL);
    assert_eq!(unsafe { cmux_agent_cursor_visibility(&good, std::ptr::null_mut()) }, ERR_NULL);

    let mut null_panes = good;
    null_panes.panes = std::ptr::null();
    assert_eq!(call(&null_panes).0, ERR_NULL);

    let mut windows = flat.windows.clone();
    windows[0].panes_count = flat.panes.len() as u32 + 1;
    let mut outside = good;
    outside.windows = windows.as_ptr();
    assert_eq!(call(&outside).0, ERR_INVALID);

    let mut windows = flat.windows.clone();
    windows[0].listed_offset = u32::MAX;
    windows[0].listed_count = u32::MAX;
    let mut overflow = good;
    overflow.windows = windows.as_ptr();
    assert_eq!(call(&overflow).0, ERR_INVALID);

    let before = CmuxCursorVisibility { kind: 9, ..CmuxCursorVisibility::default() };
    let mut kept = before;
    assert_eq!(unsafe { cmux_agent_cursor_visibility(&outside, &mut kept) }, ERR_INVALID);
    assert_eq!(kept, before, "a refused call leaves out as it was");
}
