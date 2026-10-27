//! Pane and window resize through the TUI app (Lawrence 2026-10-27: "we need
//! resize tests, for both windows, and panes too").
//!
//! Each pane runs a real child that records the size it reads from its PTY
//! (`stty size`, the TIOCGWINSZ a program sees) at start and on every
//! SIGWINCH, in a file named by its pid. After every step (a window resize,
//! a divider drag, a nested split, a close, a zoom and unzoom) the pane rects
//! tile the content area, and every visible pane's terminal grid, the size
//! its child reads and its content rect are the same.

use super::*;
use crate::app::PaneEdge;

/// Records the PTY size its child reads, as "rows cols", in `$1/<pid>`.
const SIZE_LOGGER: &str = r#"
dir=$1
report() { stty size > "$dir/$$.tmp"; mv "$dir/$$.tmp" "$dir/$$"; }
trap report WINCH
report
while :; do sleep 0.02; done
"#;

struct PaneRig {
    mux: Arc<Mux>,
    app: App,
    events: Receiver<AppEvent>,
    dir: PathBuf,
    size: (u16, u16),
}

impl PaneRig {
    fn new(name: &str, size: (u16, u16)) -> Self {
        let dir = test_temp_dir(name);
        let mux = Mux::new(
            format!("{name}-{}", std::process::id()),
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    SIZE_LOGGER.into(),
                    "sh".into(),
                    dir.to_string_lossy().into_owned(),
                ]),
                ..Default::default()
            },
        );
        mux.new_workspace(None, Some(size)).unwrap();
        let (mut app, events) = test_app_with_events(Session::Local(mux.clone()));
        app.sidebar_visible = false;
        app.replace_tree(app.session.tree());
        let mut rig = Self { mux, app, events, dir, size };
        rig.resize_window(size);
        rig
    }

    /// The host terminal (the window) is `size`: lay out and settle.
    fn resize_window(&mut self, size: (u16, u16)) {
        self.size = size;
        self.relayout();
    }

    fn relayout(&mut self) {
        self.app.sync_layout(self.size);
        settle_pending_mutations(&mut self.app, &self.events);
    }

    fn pane_of(&self, surface: SurfaceId) -> cmux_tui_core::PaneId {
        self.mux.with_state(|state| state.pane_of(surface).unwrap())
    }

    fn area(&self, pane: cmux_tui_core::PaneId) -> PaneArea {
        *self.app.pane_areas.iter().find(|area| area.pane == pane).unwrap()
    }

    /// The size the child of `surface` last read from its PTY, as (cols, rows).
    fn child_size(&self, surface: SurfaceId) -> Option<(u16, u16)> {
        let pid = self.mux.surface(surface)?.process_id()?;
        let text = std::fs::read_to_string(self.dir.join(pid.to_string())).ok()?;
        let mut parts = text.split_whitespace();
        let rows = parts.next()?.parse().ok()?;
        let cols = parts.next()?.parse().ok()?;
        Some((cols, rows))
    }

    /// The pane rects tile the content area, and every visible pane's grid,
    /// PTY (as its child reads it) and content rect agree. Returns each
    /// pane's content size.
    fn check(&self, step: &str) -> HashMap<cmux_tui_core::PaneId, (u16, u16)> {
        let content = self.app.content_area;
        let areas = &self.app.pane_areas;
        assert!(!areas.is_empty(), "{step}: no pane is laid out");
        let covered: u32 =
            areas.iter().map(|area| u32::from(area.rect.width) * u32::from(area.rect.height)).sum();
        assert_eq!(
            covered,
            u32::from(content.width) * u32::from(content.height),
            "{step}: the pane rects do not tile the {}x{} content area: {:?}",
            content.width,
            content.height,
            areas.iter().map(|area| area.rect).collect::<Vec<_>>()
        );
        for (i, a) in areas.iter().enumerate() {
            for b in &areas[i + 1..] {
                let overlap_x =
                    a.rect.x < b.rect.x + b.rect.width && b.rect.x < a.rect.x + a.rect.width;
                let overlap_y =
                    a.rect.y < b.rect.y + b.rect.height && b.rect.y < a.rect.y + a.rect.height;
                assert!(
                    !(overlap_x && overlap_y),
                    "{step}: panes overlap: {:?} {:?}",
                    a.rect,
                    b.rect
                );
            }
        }
        let mut sizes = HashMap::new();
        for area in areas {
            let expected = area.content_size();
            assert!(
                area.content.x >= area.rect.x
                    && area.content.y >= area.rect.y
                    && area.content.x + area.content.width <= area.rect.x + area.rect.width
                    && area.content.y + area.content.height <= area.rect.y + area.rect.height,
                "{step}: pane {} content {:?} is outside its frame {:?}",
                area.pane,
                area.content,
                area.rect
            );
            let surface = self.mux.surface(area.surface).expect("pane surface");
            let grid = surface.with_terminal(|term| (term.cols(), term.rows())).unwrap();
            assert_eq!(
                grid, expected,
                "{step}: pane {} terminal grid vs its content rect",
                area.pane
            );
            assert_eq!(surface.size(), expected, "{step}: pane {} surface size", area.pane);
            let deadline = Instant::now() + crate::test_wait::EVENT;
            loop {
                let seen = self.child_size(area.surface);
                if seen == Some(expected) {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "{step}: pane {}'s program reads {seen:?} from its PTY, its content is {expected:?}",
                    area.pane
                );
                std::thread::sleep(Duration::from_millis(5));
            }
            sizes.insert(area.pane, expected);
        }
        sizes
    }

    /// Drags `pane`'s `edge` handle to column `xs` in turn, one drag event
    /// per column like a mouse, and releases on the last.
    fn drag_divider(&mut self, pane: cmux_tui_core::PaneId, edge: PaneEdge, xs: &[u16]) {
        let mut terminal = Terminal::new(TestBackend::new(self.size.0, self.size.1)).unwrap();
        terminal.draw(|frame| crate::ui::draw(&mut self.app, frame)).unwrap();
        let handle = self
            .app
            .hits
            .iter()
            .find_map(|(rect, hit)| {
                matches!(
                    hit,
                    crate::app::Hit::PaneResize { horizontal: Some((p, e)), vertical: None }
                        if *p == pane && *e == edge
                )
                .then_some(*rect)
            })
            .expect("the divider exposes a drag handle");
        let y = handle.y + handle.height / 2;
        self.app.handle_left_down(handle.x, y, KeyModifiers::NONE).unwrap();
        assert!(
            matches!(self.app.drag, Some(Drag::ResizeSplit { .. })),
            "the press did not grab the divider"
        );
        for &x in xs {
            self.app.handle_left_drag(x, y).unwrap();
        }
        self.app.handle_left_up(*xs.last().unwrap(), y).unwrap();
        settle_pending_mutations(&mut self.app, &self.events);
        self.relayout();
    }

    fn close(self) {
        let surfaces =
            self.mux.with_state(|state| state.surfaces.keys().copied().collect::<Vec<_>>());
        for surface in surfaces {
            let _ = self.mux.close_surface(surface);
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// A window resize resizes the one pane's terminal to its new frame through
/// a grow, a shrink, a drag of the window edge, a tiny window and a huge one.
#[test]
fn window_resize_resizes_the_pane_terminal_to_its_frame() {
    let mut rig = PaneRig::new("pane-resize-window", (80, 24));
    rig.check("start");
    for size in [(120, 40), (60, 20), (300, 90), (12, 6), (5, 4), (1000, 300), (80, 24)] {
        rig.resize_window(size);
        rig.check(&format!("window {}x{}", size.0, size.1));
    }
    // A live window drag: one layout per frame; every frame lands.
    for frame in 0..30u16 {
        rig.resize_window((60 + frame * 3, 20 + frame / 2));
        rig.check(&format!("window drag frame {frame}"));
    }
    rig.close();
}

/// One pane split right: (left, right).
fn split_right(rig: &mut PaneRig) -> (cmux_tui_core::PaneId, cmux_tui_core::PaneId) {
    let first = rig.app.active_surface().unwrap();
    let left = rig.pane_of(first);
    let second = rig.mux.split(left, SplitDir::Right, Some((50, 30))).unwrap();
    let right = rig.pane_of(second.id);
    rig.relayout();
    let split = rig.check("split right");
    assert_eq!(split.len(), 2);
    (left, right)
}

/// A split's divider drag with the mouse resizes both panes, each terminal
/// to its own new width, one drag event per column; the panes keep tiling
/// the window.
#[test]
fn divider_drag_resizes_both_pane_terminals() {
    let mut rig = PaneRig::new("pane-resize-divider", (100, 30));
    let (left, right) = split_right(&mut rig);
    let split = rig.check("before the drag");
    let (left_before, right_before) = (split[&left], split[&right]);

    // Drag the divider left, one column per event, then back right past
    // where it started.
    let start = rig.area(left).rect.x + rig.area(left).rect.width - 1;
    let leftward: Vec<u16> = (start - 25..start).rev().collect();
    rig.drag_divider(left, PaneEdge::Right, &leftward);
    let dragged = rig.check("divider dragged left");
    assert!(dragged[&left].0 < left_before.0, "the left pane did not narrow: {dragged:?}");
    assert!(dragged[&right].0 > right_before.0, "the right pane did not widen: {dragged:?}");
    assert_eq!(dragged[&left].1, left_before.1, "a horizontal drag changed the rows");
    let at = rig.area(left).rect.x + rig.area(left).rect.width - 1;
    let rightward: Vec<u16> = (at + 1..=at + 40).collect();
    rig.drag_divider(left, PaneEdge::Right, &rightward);
    let back = rig.check("divider dragged right");
    assert!(back[&left].0 > left_before.0, "the left pane did not widen: {back:?}");
    assert!(back[&right].0 < right_before.0, "the right pane did not narrow: {back:?}");
    rig.close();
}

/// A divider moved by another client, a nested split, a window resize with
/// three panes, a zoom and unzoom, and closes that give the space back each
/// leave every visible pane's grid, PTY and child on its frame.
#[test]
fn nested_split_zoom_and_close_resize_every_pane_terminal() {
    let mut rig = PaneRig::new("pane-resize-nested", (100, 30));
    let (left, right) = split_right(&mut rig);
    let before = rig.check("before the ratio change");
    let split = rig.mux.with_state(|state| {
        let Node::Split { id, .. } = &state.workspaces[0].screens[0].root else {
            panic!("expected a split root");
        };
        *id
    });
    assert!(rig.mux.set_split_ratio_as(crate::local_actor::me(), split, 0.7));
    rig.relayout();
    let back = rig.check("divider at 0.7");
    assert!(back[&left].0 > before[&left].0 && back[&right].0 < before[&right].0, "{back:?}");

    // Nested: split the right pane down.
    let third = rig.mux.split(right, SplitDir::Down, Some((30, 14))).unwrap();
    let bottom = rig.pane_of(third.id);
    rig.relayout();
    let nested = rig.check("nested split down");
    assert_eq!(nested.len(), 3);
    assert_eq!(nested[&right].0, nested[&bottom].0, "the stacked panes have different widths");
    assert!(nested[&right].1 < back[&right].1, "the top pane kept its rows after the split");

    // The window resizes with three panes.
    for size in [(160, 50), (70, 20), (40, 12), (120, 36)] {
        rig.resize_window(size);
        rig.check(&format!("three panes, window {}x{}", size.0, size.1));
    }

    // Zoom the bottom pane: it takes the whole content area.
    let before_zoom = rig.check("before zoom");
    rig.mux.zoom_pane(Some(bottom), ZoomMode::On).unwrap();
    rig.relayout();
    let zoomed = rig.check("zoomed");
    assert_eq!(zoomed.len(), 1, "the zoomed screen shows other panes: {zoomed:?}");
    assert!(
        zoomed[&bottom].0 > before_zoom[&bottom].0 && zoomed[&bottom].1 > before_zoom[&bottom].1
    );
    rig.resize_window((140, 44));
    rig.check("zoomed, window resized");
    rig.resize_window((120, 36));
    rig.mux.zoom_pane(Some(bottom), ZoomMode::Off).unwrap();
    rig.relayout();
    let unzoomed = rig.check("unzoomed");
    assert_eq!(unzoomed, before_zoom, "unzoom did not give every pane its size back");

    // Close the bottom pane: the top-right pane takes its rows back.
    rig.mux.close_pane(bottom).unwrap();
    rig.relayout();
    let closed = rig.check("closed the bottom pane");
    assert_eq!(closed.len(), 2);
    assert!(closed[&right].1 > unzoomed[&right].1, "the closed pane's rows were not given back");
    // Close the right pane: the left one takes the whole window.
    rig.mux.close_pane(right).unwrap();
    rig.relayout();
    let alone = rig.check("closed the right pane");
    assert_eq!(alone.len(), 1);
    assert!(alone[&left].0 > closed[&left].0, "the closed pane's columns were not given back");
    rig.close();
}
