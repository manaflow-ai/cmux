//! Per-frame sidebar work is flat in the person's data: a paint frame (the
//! frame PTY output and typing draw, with no layout pass) probes and
//! allocates the same at 100 items as at 10,000. Every rail is on screen and
//! scrolled to the middle of its list: machines, workspaces with recoverable
//! workspaces and the agents section, tabs, a projection tree, and files.
//!
//! `sidebar_paint_frame_cost_report` (ignored) prints ms and allocations per
//! frame for the PR's before/after table:
//! `cargo test -p cmux-tui sidebar_paint_frame_cost_report -- --ignored --nocapture`.

use super::*;
use crate::session::AgentInfo;

const FRAME: (u16, u16) = (200, 40);
const SMALL: usize = 100;
const LARGE: usize = 10_000;

fn tab(surface: SurfaceId, title: String) -> TabView {
    TabView {
        surface,
        public_id: None,
        content_id: None,
        terminal_id: None,
        short_id: format!("t{surface}"),
        name: None,
        title,
        kind: SurfaceKind::Pty,
        browser_source: None,
        browser_frames_stalled: false,
        supports_clear_history_key_fallback: false,
        notification: None,
        program_status: None,
        attention: None,
        git_branch: None,
    }
}

/// `items` workspaces of one tab each; the first workspace holds `items`
/// tabs, so the tabs rail and the projection's tab level are long too.
fn tree_with(items: usize) -> TreeView {
    let workspaces = (0..items)
        .map(|index| {
            let id = index as u64 + 1;
            let pane = 2_000_000 + id;
            let tabs = if index == 0 {
                (0..items)
                    .map(|tab_index| tab(1_000_000 + tab_index as u64, format!("tab {tab_index}")))
                    .collect()
            } else {
                vec![tab(3_000_000 + id, format!("shell {index}"))]
            };
            WorkspaceView {
                id,
                resource_id: None,
                key: format!("workspace-{id}"),
                short_id: format!("w{id}"),
                name: format!("workspace {index}"),
                active_screen: 0,
                screens: vec![ScreenView {
                    id: 4_000_000 + id,
                    resource_id: None,
                    short_id: format!("s{id}"),
                    name: None,
                    layout: Node::Leaf(pane),
                    active_pane: pane,
                    zoomed_pane: None,
                    viewport_base_width: None,
                    viewport_splits: BTreeMap::new(),
                    panes: vec![PaneView {
                        id: pane,
                        resource_id: None,
                        short_id: format!("p{id}"),
                        name: None,
                        active_tab: 0,
                        focused_at: 0,
                        tabs,
                    }],
                }],
            }
        })
        .collect();
    TreeView::from_parts(workspaces, 1, Some(1), 0)
}

/// One working agent in every workspace's first tab.
fn agents_for(tree: &TreeView) -> Vec<AgentInfo> {
    tree.workspaces()
        .iter()
        .map(|workspace| AgentInfo {
            surface: workspace.screens[0].panes[0].tabs[0].surface,
            state: "working".into(),
            source: "hook".into(),
            session: None,
            agent: Some("codex".into()),
            updated_at_ms: workspace.id,
        })
        .collect()
}

fn machine_ui_with(items: usize) -> MachineUiState {
    let machines = (0..items)
        .map(|index| MachineDescriptor {
            key: MachineKey(index as u64 + 1),
            id: format!("machine-{index}"),
            name: format!("machine {index}"),
            subtitle: "cloud".into(),
            status: MachineStatus::Running,
            platform: None,
            capabilities: Vec::new(),
        })
        .collect();
    let mut ui = MachineUiState::new(MachineSnapshot {
        machines,
        active: Some(MachineKey(1)),
        capabilities: MachineCapabilities { create: true, connect: true },
    });
    ui.set_managed_workspaces(
        MachineKey(1),
        (0..items)
            .map(|index| ManagedWorkspaceDescriptor {
                id: format!("00000000-0000-4000-8000-{index:012}"),
                name: format!("recoverable {index}"),
                mode: WorkspaceCreationMode::Isolated,
                status: ManagedWorkspaceStatus::Recoverable,
                version: 1,
                recoverable_until: Some("2030-01-02T03:04:05Z".into()),
                capabilities: ManagedWorkspaceCapabilities {
                    rename: false,
                    delete: false,
                    restore: true,
                    purge: true,
                },
            })
            .collect(),
    );
    ui
}

struct Scenario {
    app: App,
    terminal: Terminal<TestBackend>,
    _mux: Arc<Mux>,
    _surface: Arc<cmux_tui_core::Surface>,
    _files: Option<tempfile::TempDir>,
}

impl Scenario {
    fn draw(&mut self) {
        let app = &mut self.app;
        self.terminal.draw(|frame| crate::ui::draw(app, frame)).unwrap();
    }

    /// Body-row probes and allocation calls of one paint frame.
    fn measure_frame(&mut self) -> (usize, usize) {
        crate::ui::take_body_row_probes();
        let ((), allocations) = crate::test_alloc::count_allocations(|| self.draw());
        (crate::ui::take_body_row_probes(), allocations)
    }
}

/// The rails with `items` entries each, scrolled to the middle, after the
/// layout frame and two warm paint frames.
fn scenario(items: usize, view: SidebarView) -> Scenario {
    let (mux, surface) = test_mux(&format!("sidebar-frame-cost-{items}-{view:?}"), None);
    let mut app = test_app(Session::Local(mux.clone()));
    app.config.sidebar.columns_explicit = true;
    app.config.sidebar.columns = vec![
        crate::config::SidebarColumn { kind: SidebarColumnKind::Machines, width: 30, max_width: 0 },
        crate::config::SidebarColumn {
            kind: SidebarColumnKind::Workspaces,
            width: 30,
            max_width: 0,
        },
        crate::config::SidebarColumn { kind: SidebarColumnKind::Tabs, width: 30, max_width: 0 },
    ];
    let mut views = app
        .config
        .sidebar
        .columns
        .iter()
        .map(|column| SidebarViewSpec::legacy(column.kind, column.width, column.max_width))
        .collect::<Vec<_>>();
    views.push(SidebarViewSpec {
        id: "workspace-tabs".into(),
        levels: vec![SidebarResourceKind::Workspaces, SidebarResourceKind::Tabs],
        actions: Vec::new(),
        actions_position: crate::config::ActionsPosition::Bottom,
        width: 30,
        max_width: 0,
        collapse_priority: 30,
    });
    app.config.sidebar.views = views;
    app.config.sidebar.views_explicit = true;
    app.sidebar_view = view;
    app.machine_ui = Some(machine_ui_with(items));
    app.replace_tree(app.session.tree());
    app.sync_layout(FRAME);
    assert!(app.sidebar_layout.machine.is_some(), "machine rail on screen");
    assert!(app.sidebar_layout.workspace.is_some(), "workspace rail on screen");
    assert!(app.sidebar_layout.tabs.is_some(), "tabs rail on screen");
    assert!(app.projection_sidebar_area(3).is_some(), "projection rail on screen");

    // Paint frames draw the adopted tree and the roster of the last layout
    // frame; give both `items` entries.
    let tree = tree_with(items);
    app.sidebar_status = crate::sidebar_status::SidebarStatus::build(&tree, &agents_for(&tree));
    app.tree = tree;
    app.sidebar_workspace_selection = 0;
    // Rail scroll offsets count rows; an entry is `row_height + row_gap` rows.
    let stride =
        usize::from(app.config.sidebar.row_height.max(1)) + usize::from(app.config.sidebar.row_gap);
    // Three quarters down the workspaces, above the recoverable ones.
    app.workspace_rail_scroll = items * 3 / 4 * stride;
    app.machine_rail_scroll = items / 2 * stride;
    app.tabs_rail_scroll = items / 2;
    app.agent_section_scroll = items / 2;
    app.projection_rail_state_mut(3).scroll = items;
    let files = (view == SidebarView::Files).then(|| {
        let dir = tempfile::tempdir().unwrap();
        for index in 0..items {
            std::fs::write(dir.path().join(format!("file-{index:05}.txt")), b"").unwrap();
        }
        app.sidebar_files = FileBrowser::new(dir.path().to_path_buf());
        app.sidebar_files.reroot(dir.path().to_path_buf());
        app.sidebar_files.select(items / 2);
        dir
    });
    let terminal = Terminal::new(TestBackend::new(FRAME.0, FRAME.1)).unwrap();
    let mut scenario = Scenario { app, terminal, _mux: mux, _surface: surface, _files: files };
    scenario.draw();
    scenario.draw();
    scenario
}

fn assert_flat(view: SidebarView) {
    let (small_probes, small_allocations) = scenario(SMALL, view).measure_frame();
    let mut large = scenario(LARGE, view);
    let (large_probes, large_allocations) = large.measure_frame();
    // The frame drew the middle of each list, not its head.
    if view == SidebarView::Workspaces {
        assert!(
            large.app.hits.iter().any(|(_, hit)| matches!(
                hit,
                crate::app::Hit::Workspace { index, .. } if *index > LARGE / 2
            )),
            "the workspace rail drew rows from the middle of its list"
        );
    } else {
        assert!(
            large.app.hits.iter().any(|(_, hit)| matches!(
                hit,
                crate::app::Hit::SidebarFile { index } if *index >= LARGE / 2 - 40
            )),
            "the files rail drew rows around its selection"
        );
    }
    let within = |small: usize, large: usize| large <= small + small / 10 + 4;
    assert!(
        within(small_probes, large_probes),
        "{view:?}: a paint frame probed {small_probes} rows at {SMALL} items and \
         {large_probes} at {LARGE}: rails must visit only rows in their viewport"
    );
    assert!(
        within(small_allocations, large_allocations),
        "{view:?}: a paint frame allocated {small_allocations} times at {SMALL} items and \
         {large_allocations} at {LARGE}: rails must not clone or rebuild their lists per frame"
    );
}

#[test]
fn workspace_rails_paint_frame_cost_is_flat_in_items() {
    assert_flat(SidebarView::Workspaces);
}

#[test]
fn files_rail_paint_frame_cost_is_flat_in_items() {
    assert_flat(SidebarView::Files);
}

#[test]
#[ignore = "prints the before/after table; run with --ignored --nocapture"]
fn sidebar_paint_frame_cost_report() {
    const FRAMES: u32 = 50;
    for view in [SidebarView::Workspaces, SidebarView::Files] {
        for items in [SMALL, LARGE] {
            let mut scenario = scenario(items, view);
            let (probes, _) = scenario.measure_frame();
            let mut allocations = 0;
            let started = Instant::now();
            for _ in 0..FRAMES {
                let ((), made) = crate::test_alloc::count_allocations(|| scenario.draw());
                allocations += made;
            }
            let elapsed = started.elapsed();
            println!(
                "sidebar-frame-cost view={view:?} items={items} ms_per_frame={:.3} \
                 allocations_per_frame={} body_rows_probed={probes}",
                elapsed.as_secs_f64() * 1000.0 / f64::from(FRAMES),
                allocations / FRAMES as usize,
            );
        }
    }
}
