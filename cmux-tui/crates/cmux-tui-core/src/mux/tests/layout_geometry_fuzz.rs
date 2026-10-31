//! Layout geometry fuzz (fuzz catalog row d, 2026-10-31): random layout op
//! sequences on the daemon's own `Mux`, with these oracles after every step.
//!
//! - R3b: an op that creates (a column, a split, a pane, a tab) never changes
//!   the width of an existing column, exactly (the f32 bits). A screen
//!   without columns is one implicit column of width 1.0. A column resize
//!   changes only its own column.
//! - SIZES: at a random viewport, the panes of each screen tile its strip:
//!   each pane once, no two overlap, the areas sum to the strip, and the
//!   columns are contiguous from x = 0.
//! - FOCUS: the active workspace, screen, pane, zoomed pane and active tab
//!   exist.
//! - UNDO: an op that records one undo entry, then its undo, gives the
//!   screen's layout before the op back (root, columns, widths, zoom). The
//!   daemon has no layout redo, so there is no redo to round-trip.
//! - REDUCER: the projection to `cmux_layout_reducer` holds I1-I3, and the
//!   daemon never rejected an op because its result and the reducer's differ.
//!
//! The layout_invariants proptest covers tab conservation of moves; this
//! one covers geometry. `CMUX_LAYOUT_FUZZ_CASES` sets the number of sequences
//! (default 96). A failure prints the shrunk op list: paste it into a red test.

use std::collections::BTreeMap;

use super::*;
use crate::mux::layout_invariants::{project, rejections_on_this_thread};
use cmux_layout_reducer::check_state;
use proptest::prelude::*;

#[derive(Debug, Clone)]
enum Op {
    /// `new_column`: a viewport column beside the pane's column.
    NewColumn {
        pane: usize,
        width: f32,
        before: bool,
        undo: bool,
    },
    /// `split` of a pane.
    Split {
        pane: usize,
        down: bool,
        undo: bool,
    },
    /// `new_pane`: the Zellij auto-layout pane in the pane's column.
    NewPane {
        pane: usize,
        undo: bool,
    },
    /// `new_tab` in a pane.
    NewTab {
        pane: usize,
    },
    /// A tab dragged into a new column.
    TabToColumn {
        tab: usize,
        pane: usize,
        width: Option<f32>,
    },
    /// `set_viewport_pane_width` of the pane's column.
    ResizeColumn {
        pane: usize,
        width: f32,
    },
    /// `set_ratio` of the pane's nearest split on an axis.
    ResizeSplit {
        pane: usize,
        down: bool,
        ratio: f32,
    },
    Zoom {
        pane: usize,
        mode: u8,
    },
    Focus {
        pane: usize,
    },
    ClosePane {
        pane: usize,
    },
    CloseTab {
        tab: usize,
    },
    Undo {
        pane: usize,
    },
}

impl Op {
    /// Ops that must leave every existing column's width as it was: the
    /// creates, and zoom and focus, which change no width either.
    fn creates(&self) -> bool {
        matches!(
            self,
            Self::NewColumn { .. }
                | Self::Split { .. }
                | Self::NewPane { .. }
                | Self::NewTab { .. }
                | Self::TabToColumn { .. }
                | Self::Zoom { .. }
                | Self::Focus { .. }
        )
    }

    fn undo_after(&self) -> bool {
        matches!(
            self,
            Self::NewColumn { undo: true, .. }
                | Self::Split { undo: true, .. }
                | Self::NewPane { undo: true, .. }
        )
    }
}

fn width() -> impl Strategy<Value = f32> {
    prop_oneof![
        6 => 0.1f32..=1.0,
        1 => Just(0.5f32),
        1 => Just(1.0f32),
        1 => Just(0.1f32),
        1 => Just(2.0f32 / 3.0),
        1 => prop_oneof![Just(0.0f32), Just(0.05f32), Just(1.5f32)],
    ]
}

fn op() -> impl Strategy<Value = Op> {
    let pick = 0..64usize;
    prop_oneof![
        4 => (pick.clone(), width(), any::<bool>(), any::<bool>())
            .prop_map(|(pane, width, before, undo)| Op::NewColumn { pane, width, before, undo }),
        3 => (pick.clone(), any::<bool>(), any::<bool>())
            .prop_map(|(pane, down, undo)| Op::Split { pane, down, undo }),
        2 => (pick.clone(), any::<bool>()).prop_map(|(pane, undo)| Op::NewPane { pane, undo }),
        1 => pick.clone().prop_map(|pane| Op::NewTab { pane }),
        2 => (pick.clone(), pick.clone(), prop::option::of(width()))
            .prop_map(|(tab, pane, width)| Op::TabToColumn { tab, pane, width }),
        3 => (pick.clone(), width()).prop_map(|(pane, width)| Op::ResizeColumn { pane, width }),
        2 => (pick.clone(), any::<bool>(), 0.0f32..=1.0)
            .prop_map(|(pane, down, ratio)| Op::ResizeSplit { pane, down, ratio }),
        1 => (pick.clone(), 0..3u8).prop_map(|(pane, mode)| Op::Zoom { pane, mode }),
        1 => pick.clone().prop_map(|pane| Op::Focus { pane }),
        2 => pick.clone().prop_map(|pane| Op::ClosePane { pane }),
        1 => pick.clone().prop_map(|tab| Op::CloseTab { tab }),
        2 => pick.prop_map(|pane| Op::Undo { pane }),
    ]
}

fn pick<T: Copy>(items: &[T], index: usize) -> Option<T> {
    (!items.is_empty()).then(|| items[index % items.len()])
}

/// Live panes and tabs in a stable order, for index picks.
fn live(mux: &Mux) -> (Vec<PaneId>, Vec<SurfaceId>) {
    mux.with_state(|state| {
        let mut panes = Vec::new();
        let mut tabs = Vec::new();
        for workspace in &state.workspaces {
            for screen in &workspace.screens {
                for pane in screen.root.pane_ids_vec() {
                    panes.push(pane);
                    if let Some(record) = state.panes.get(&pane) {
                        tabs.extend(record.tabs.iter().copied());
                    }
                }
            }
        }
        (panes, tabs)
    })
}

/// Each live pane's screen, column and column width. A screen without
/// columns is one implicit column (`None`) of width 1.0.
type Widths = BTreeMap<PaneId, (ScreenId, Option<SplitId>, f32)>;

fn column_widths(state: &State) -> Widths {
    let mut widths = Widths::new();
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            if screen.layout_columns.is_empty() {
                for pane in screen.root.pane_ids_vec() {
                    widths.insert(pane, (screen.id, None, 1.0));
                }
            }
            for column in &screen.layout_columns {
                for pane in column.root.pane_ids_vec() {
                    widths.insert(pane, (screen.id, Some(column.id), column.width));
                }
            }
        }
    }
    widths
}

/// A split tree without the stack selection, which is focus state.
fn shape(node: &Node) -> String {
    match node {
        Node::Leaf(pane) => format!("{pane}"),
        Node::Split { id, dir, ratio, a, b } => {
            format!("({id} {dir:?} {:#x} {} {})", ratio.to_bits(), shape(a), shape(b))
        }
        Node::Stack { panes, .. } => format!("stack{:?}", panes.as_slice()),
    }
}

/// The structural layout of the screen holding `pane`, without focus.
fn screen_layout(state: &State, pane: PaneId) -> Option<(ScreenId, String, usize)> {
    let (workspace, screen) = state.screen_of(pane)?;
    let screen = &state.workspaces[workspace].screens[screen];
    let columns = screen
        .layout_columns
        .iter()
        .map(|column| {
            format!(
                "[{} {:#x} {} auto={:?} dock={:?} rows={:?}]",
                column.id,
                column.width.to_bits(),
                shape(&column.root),
                column.creation_order_auto_layout,
                column.dock,
                column.rows,
            )
        })
        .collect::<String>();
    let layout = format!(
        "root={} zoomed={:?} auto={:?} splits={:?} base={:?} columns={columns}",
        shape(&screen.root),
        screen.zoomed_pane,
        screen.creation_order_auto_layout,
        screen.viewport_splits,
        screen.viewport_base_width,
    );
    Some((screen.id, layout, screen.layout_undo.len()))
}

/// Screens on which a pane of `before` is gone: a close there may collapse
/// columns, which R3b does not judge.
fn screens_that_lost_a_pane(before: &Widths, after: &Widths) -> Vec<ScreenId> {
    before
        .iter()
        .filter(|(pane, (screen, _, _))| after.get(*pane).is_none_or(|(now, _, _)| now != screen))
        .map(|(_, (screen, _, _))| *screen)
        .collect()
}

/// R3b: every column of `before` keeps its exact width in `after`, except
/// `exempt` (a resized column) and screens that lost a pane.
fn check_r3b(
    before: &Widths,
    after: &Widths,
    exempt: Option<(ScreenId, Option<SplitId>)>,
    op: &Op,
) -> Result<(), String> {
    let lost = screens_that_lost_a_pane(before, after);
    for (pane, (screen, column, width)) in before {
        if lost.contains(screen) || exempt == Some((*screen, *column)) {
            continue;
        }
        let Some((after_screen, after_column, after_width)) = after.get(pane) else { continue };
        if after_width.to_bits() != width.to_bits() {
            return Err(format!(
                "R3b: {op:?} changed the width of pane {pane}'s column on screen {screen}: \
                 {column:?} {width} -> screen {after_screen} {after_column:?} {after_width}"
            ));
        }
    }
    Ok(())
}

fn viewport_cells(viewport: u16, width: f32) -> u64 {
    let width = width.clamp(MIN_VIEWPORT_PANE_WIDTH, MAX_VIEWPORT_PANE_WIDTH);
    u64::from(((f32::from(viewport) * width).round() as u16).clamp(1, viewport.max(1)))
}

fn check_sizes(state: &State, cols: u16, rows: u16) -> Result<(), String> {
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            let layout = layout_screen_with_viewport(
                &screen.root,
                Rect { x: 0, y: 0, width: cols, height: rows },
                Some(screen.active_pane),
                screen.viewport_base_width.unwrap_or(1.0),
                &screen.viewport_splits,
            );
            let mut expected = screen.root.pane_ids_vec();
            expected.sort_unstable();
            let mut laid = layout.panes.iter().map(|(pane, _)| *pane).collect::<Vec<_>>();
            laid.sort_unstable();
            if laid != expected {
                return Err(format!(
                    "SIZES: screen {} at {cols}x{rows} lays out panes {laid:?}, its tree has {expected:?}",
                    screen.id
                ));
            }
            let rects = layout
                .panes
                .iter()
                .filter(|(_, rect)| rect.width > 0 && rect.height > 0)
                .collect::<Vec<_>>();
            for (index, (first, a)) in rects.iter().enumerate() {
                for (second, b) in &rects[index + 1..] {
                    let overlap_x = a.x < b.x + b.width && b.x < a.x + a.width;
                    let overlap_y = a.y < b.y + b.height && b.y < a.y + a.height;
                    if overlap_x && overlap_y {
                        return Err(format!(
                            "SIZES: screen {} at {cols}x{rows}: pane {first} {a:?} overlaps pane {second} {b:?}",
                            screen.id
                        ));
                    }
                }
            }
            let end = layout.panes.iter().map(|(_, rect)| rect.x + rect.width).max().unwrap_or(0);
            let area: u64 = rects.iter().map(|(_, rect)| rect.width * u64::from(rect.height)).sum();
            if area != end * u64::from(rows) {
                return Err(format!(
                    "SIZES: screen {} at {cols}x{rows}: pane areas sum to {area}, the strip is {end}x{rows}: {:?}",
                    screen.id, layout.panes
                ));
            }
            if !screen.layout_columns.is_empty() {
                let mut x = 0u64;
                for column in &screen.layout_columns {
                    let cells = viewport_cells(cols, column.width);
                    for pane in column.root.pane_ids_vec() {
                        let Some(rect) = layout.rect_of(pane) else { continue };
                        if rect.width > 0 && (rect.x < x || rect.x + rect.width > x + cells) {
                            return Err(format!(
                                "SIZES: screen {} at {cols}x{rows}: pane {pane} {rect:?} is outside its column {} [{x}, {})",
                                screen.id,
                                column.id,
                                x + cells
                            ));
                        }
                    }
                    x += cells;
                }
                if x != end {
                    return Err(format!(
                        "SIZES: screen {} at {cols}x{rows}: columns sum to {x} cells, the panes end at {end}",
                        screen.id
                    ));
                }
                if !screen.layout_column_projection_is_consistent() {
                    return Err(format!(
                        "SIZES: screen {}: the column projection is inconsistent",
                        screen.id
                    ));
                }
            }
        }
    }
    Ok(())
}

fn check_focus(state: &State) -> Result<(), String> {
    if !state.workspaces.is_empty() && state.active_workspace >= state.workspaces.len() {
        return Err(format!(
            "FOCUS: active workspace {} of {}",
            state.active_workspace,
            state.workspaces.len()
        ));
    }
    for workspace in &state.workspaces {
        if !workspace.screens.is_empty() && workspace.active_screen >= workspace.screens.len() {
            return Err(format!(
                "FOCUS: workspace {} active screen {} of {}",
                workspace.id,
                workspace.active_screen,
                workspace.screens.len()
            ));
        }
        for screen in &workspace.screens {
            if !screen.root.contains(screen.active_pane) {
                return Err(format!(
                    "FOCUS: screen {} active pane {} is not in its tree {:?}",
                    screen.id, screen.active_pane, screen.root
                ));
            }
            if let Some(zoomed) = screen.zoomed_pane
                && !screen.root.contains(zoomed)
            {
                return Err(format!(
                    "FOCUS: screen {} zoomed pane {zoomed} is not in its tree",
                    screen.id
                ));
            }
            for pane in screen.root.pane_ids_vec() {
                let Some(record) = state.panes.get(&pane) else {
                    return Err(format!("FOCUS: screen {} names missing pane {pane}", screen.id));
                };
                if record.active_tab >= record.tabs.len() {
                    return Err(format!(
                        "FOCUS: pane {pane} active tab {} of {}",
                        record.active_tab,
                        record.tabs.len()
                    ));
                }
            }
        }
    }
    Ok(())
}

/// Undo the latest layout transaction on `pane`'s screen, confirming the
/// close of created panes. Whether it undid something.
fn undo(mux: &Arc<Mux>, pane: PaneId) -> bool {
    match mux.undo_layout(pane, None, false) {
        Ok(LayoutUndoResult::Undone { .. }) => true,
        Ok(LayoutUndoResult::ConfirmationRequired { revision, .. }) => matches!(
            mux.undo_layout(pane, Some(revision), true),
            Ok(LayoutUndoResult::Undone { .. })
        ),
        Err(_) => false,
    }
}

fn zoom_mode(mode: u8) -> ZoomMode {
    match mode {
        0 => ZoomMode::Toggle,
        1 => ZoomMode::On,
        _ => ZoomMode::Off,
    }
}

/// Run `op`; the pane it targets, if it names one.
fn run(mux: &Arc<Mux>, op: &Op) -> Option<PaneId> {
    let (panes, tabs) = live(mux);
    let pane_at = |index: usize| pick(&panes, index);
    let tab_at = |index: usize| pick(&tabs, index);
    match op {
        Op::NewColumn { pane, width, before, .. } => {
            let pane = pane_at(*pane)?;
            let _ = mux.new_column_with_options_as(
                &Actor::Daemon,
                pane,
                *width,
                *before,
                TerminalSpawnOptions::default(),
                None,
            );
            Some(pane)
        }
        Op::Split { pane, down, .. } => {
            let pane = pane_at(*pane)?;
            let dir = if *down { SplitDir::Down } else { SplitDir::Right };
            let _ = mux.split(pane, dir, None);
            Some(pane)
        }
        Op::NewPane { pane, .. } => {
            let pane = pane_at(*pane)?;
            let _ = mux.new_pane(pane, None);
            Some(pane)
        }
        Op::NewTab { pane } => {
            let pane = pane_at(*pane)?;
            let _ = mux.new_tab(Some(pane), None, None);
            Some(pane)
        }
        Op::TabToColumn { tab, pane, width } => {
            let (tab, pane) = (tab_at(*tab)?, pane_at(*pane)?);
            let _ = mux.move_tab_to_column(tab, pane, None, *width, None, None);
            Some(pane)
        }
        Op::ResizeColumn { pane, width } => {
            let pane = pane_at(*pane)?;
            let _ = mux.set_viewport_pane_width(pane, *width);
            Some(pane)
        }
        Op::ResizeSplit { pane, down, ratio } => {
            let pane = pane_at(*pane)?;
            let dir = if *down { SplitDir::Down } else { SplitDir::Right };
            let _ = mux.set_ratio(pane, dir, *ratio);
            Some(pane)
        }
        Op::Zoom { pane, mode } => {
            let pane = pane_at(*pane)?;
            let _ = mux.zoom_pane(Some(pane), zoom_mode(*mode));
            Some(pane)
        }
        Op::Focus { pane } => {
            let pane = pane_at(*pane)?;
            let _ = mux.focus_pane(pane);
            Some(pane)
        }
        Op::ClosePane { pane } => {
            let pane = pane_at(*pane)?;
            let _ = mux.close_pane(pane);
            None
        }
        Op::CloseTab { tab } => {
            let tab = tab_at(*tab)?;
            let _ = mux.close_surface(tab);
            None
        }
        Op::Undo { pane } => {
            let pane = pane_at(*pane)?;
            let _ = undo(mux, pane);
            None
        }
    }
}

fn check_all(state: &State, cols: u16, rows: u16, rejections: usize) -> Result<(), String> {
    check_sizes(state, cols, rows)?;
    check_focus(state)?;
    let violations = check_state(&project(state));
    if !violations.is_empty() {
        return Err(format!("REDUCER: the projected layout breaks I1-I3: {violations:?}"));
    }
    if rejections_on_this_thread() != rejections {
        return Err("REDUCER: the daemon rejected an op whose result differs from the reducer's"
            .to_string());
    }
    Ok(())
}

/// One sequence: a workspace, then `ops`, with every oracle after each op.
fn run_sequence(cols: u16, rows: u16, ops: &[Op]) -> Result<(), String> {
    let mux = Mux::new_for_test("layout-geometry-fuzz", SurfaceOptions::default());
    mux.new_workspace(None, None).map_err(|error| format!("setup: {error:#}"))?;
    let rejections = rejections_on_this_thread();
    mux.with_state(|state| check_all(state, cols, rows, rejections))?;
    for (index, op) in ops.iter().enumerate() {
        let rejections = rejections_on_this_thread();
        let before = mux.with_state(Clone::clone);
        let before_widths = column_widths(&before);
        let target = run(&mux, op);
        let after = mux.with_state(Clone::clone);
        let at = |error: String| format!("step {index}: {error}");
        check_all(&after, cols, rows, rejections).map_err(at)?;
        let after_widths = column_widths(&after);
        if op.creates() {
            check_r3b(&before_widths, &after_widths, None, op).map_err(at)?;
        }
        if let (Op::ResizeColumn { .. }, Some(pane)) = (op, target)
            && let Some((screen, column, _)) = before_widths.get(&pane)
        {
            check_r3b(&before_widths, &after_widths, Some((*screen, *column)), op).map_err(at)?;
        }
        if op.undo_after()
            && let Some(pane) = target
            && let (Some((screen, layout, undo_len)), Some((after_screen, _, after_len))) =
                (screen_layout(&before, pane), screen_layout(&after, pane))
            && screen == after_screen
            && after_len == undo_len + 1
        {
            let rejections = rejections_on_this_thread();
            if !undo(&mux, pane) {
                return Err(at(format!("UNDO: {op:?} recorded an undo entry that does not undo")));
            }
            let undone = mux.with_state(Clone::clone);
            check_all(&undone, cols, rows, rejections)
                .map_err(|error| at(format!("after the undo of {op:?}: {error}")))?;
            let Some((_, undone_layout, _)) = screen_layout(&undone, pane) else {
                return Err(at(format!("UNDO: {op:?} then undo lost pane {pane}")));
            };
            if undone_layout != layout {
                return Err(at(format!(
                    "UNDO: {op:?} then undo does not give the layout back:\n before {layout}\n undone {undone_layout}"
                )));
            }
        }
    }
    Ok(())
}

fn cases() -> u32 {
    std::env::var("CMUX_LAYOUT_FUZZ_CASES").ok().and_then(|cases| cases.parse().ok()).unwrap_or(96)
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: cases(),
        failure_persistence: None,
        max_shrink_iters: 4_000,
        max_shrink_time: 60_000,
        ..ProptestConfig::default()
    })]

    #[test]
    fn layout_geometry_fuzz(
        cols in 20u16..=240,
        rows in 5u16..=80,
        ops in prop::collection::vec(op(), 1..=40),
    ) {
        if let Err(error) = run_sequence(cols, rows, &ops) {
            prop_assert!(false, "{}", error);
        }
    }
}
