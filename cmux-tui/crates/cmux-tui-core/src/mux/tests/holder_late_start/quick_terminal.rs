//! The quick terminal (`quick-terminal-v1`) across a stop and a start of the daemon.
//!
//! The quick terminal is one floating pane of its screen. Its record in `resource_floating_panes` has a mark:
//! column `quick` (0 = a floating pane, 1 = the quick terminal and it shows, 2 = the quick terminal and it is
//! hidden) and column `quick_from` (the pane that gets the focus back at a hide, or NULL). A store that a
//! build before the mark made has neither column, and such a build writes a screen's list with the 7 columns
//! that it knows.
//!
//! Each test starts the daemon on a store that it staged, with the stand-in holder of the parent module: the
//! holder answers before the start asks, so the start attaches each terminal in its own pass and no test
//! waits. Each shell is a process that the test started. So a test here shows what a start does with the
//! stored mark and with a process that a holder kept; it does not stop a daemon that ran a shell, and the
//! stand-in keeps no output of a terminal.

use cmux_layout_reducer::floating_panes::{FloatFrame, Floating};

use super::*;

/// The frame of the floating pane: the bottom right of the screen.
const FRAME: FloatFrame = FloatFrame { x: 550_000, y: 550_000, w: 450_000, h: 450_000 };

/// The table as each build before the mark makes it at an open: no statement when the table is there.
const TABLE_BEFORE_THE_MARK: &str = "CREATE TABLE IF NOT EXISTS resource_floating_panes (
       screen_id TEXT NOT NULL,
       pane_id TEXT NOT NULL,
       position INTEGER NOT NULL,
       x INTEGER NOT NULL,
       y INTEGER NOT NULL,
       w INTEGER NOT NULL,
       h INTEGER NOT NULL,
       PRIMARY KEY (screen_id, pane_id)
     );";

fn the_screen() -> ScreenPublicId {
    restore_screen_id(42)
}

/// The pane above: tiled, with the focus, with the terminal `TERMINAL`.
fn tiled_pane() -> PanePublicId {
    restore_pane_id(42)
}

/// The pane below: it floats, with the terminal `SECOND_TERMINAL`.
fn floating_pane() -> PanePublicId {
    restore_pane_id(43)
}

/// One workspace whose screen has 2 panes, one above the other, each with one tab and one terminal that ran
/// when its daemon stopped. The pane below floats at `FRAME`. The tabs, the tiled pane's first.
fn registry_with_a_floating_pane(root: &Path, session: &str) -> Vec<TabPublicId> {
    let workspace = RegistryWorkspace {
        id: 1,
        public_id: restore_workspace_id(42),
        key: "workspace-held".into(),
        name: "Held".into(),
        name_source: Default::default(),
        name_revision: 0,
        group_key: session.into(),
    };
    let panes = [tiled_pane(), floating_pane()];
    let tabs = vec![restore_tab_id(42), restore_tab_id(43)];
    let terminals = [(TERMINAL, INCARNATION), (SECOND_TERMINAL, SECOND_INCARNATION)];
    let mut changes = vec![
        ResourceChange::UpsertWorkspace {
            workspace: workspace.clone(),
            position: 0,
            active_screen: Some(the_screen()),
        },
        ResourceChange::UpsertScreen(RegistryScreen {
            public_id: the_screen(),
            workspace_id: workspace.public_id.clone(),
            position: 0,
            name: None,
            layout: RegistryLayoutNode::Split {
                split: restore_split_id(42),
                direction: "down".into(),
                ratio: 0.5,
                first: Box::new(RegistryLayoutNode::Leaf { pane: panes[0].clone() }),
                second: Box::new(RegistryLayoutNode::Leaf { pane: panes[1].clone() }),
                divider_hidden: false,
            },
            active_pane: panes[0].clone(),
            zoomed_pane: None,
            auto_layout: None,
            viewport: RegistryViewport::default(),
            floating: vec![Floating { pane: panes[1].clone(), frame: FRAME }],
        }),
    ];
    for (ordinal, (pane, tab)) in (1u64..).zip(panes.iter().zip(&tabs)) {
        changes.push(ResourceChange::UpsertPane(RegistryPane {
            public_id: pane.clone(),
            screen_id: the_screen(),
            name: None,
            active_tab: Some(tab.clone()),
            creation_ordinal: ordinal,
        }));
    }
    let seeded = terminals.iter().zip(panes.iter().zip(&tabs)).zip(42u128..);
    for ((&(terminal_id, _), (pane, tab)), seed) in seeded {
        let terminal_public_id = restore_terminal_id(seed);
        changes.push(ResourceChange::UpsertTerminal {
            public_id: terminal_public_id.clone(),
            terminal: RegistryTerminal {
                terminal_id: terminal_id.into(),
                workspace_key: workspace.key.clone(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({"command":["/bin/sh"]}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        });
        changes.push(ResourceChange::UpsertTab(RegistryTab {
            name_source: Default::default(),
            name_revision: 0,
            public_id: tab.clone(),
            pane_id: pane.clone(),
            position: 0,
            content_id: ContentPublicId::Terminal(terminal_public_id),
            name: None,
            browser_url: None,
            terminal_id: Some(terminal_id.into()),
        }));
    }
    changes.extend([
        ResourceChange::SetWorkspaceOrder { workspace_ids: vec![workspace.public_id.clone()] },
        ResourceChange::SetScreenOrder {
            workspace_id: workspace.public_id.clone(),
            screen_ids: vec![the_screen()],
        },
    ]);
    for (pane, tab) in panes.iter().zip(&tabs) {
        changes.push(ResourceChange::SetTabOrder {
            pane_id: pane.clone(),
            tab_ids: vec![tab.clone()],
        });
    }
    changes.push(ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id) });
    let mut registry = WorkspaceRegistry::open(root, session).unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon("seed-floating-terminal", "test").unwrap(),
            "workspace.create",
            &serde_json::json!({"fixture":"floating-terminal"}),
            None,
            Some(0),
            &ResourcePatch { changes },
            &serde_json::json!({"created":true}),
            &serde_json::json!([{"kind":"fixture.created"}]),
        )
        .unwrap();
    for (terminal_id, incarnation) in terminals {
        commit_terminal_lifecycle(
            &mut registry,
            "terminal-ready",
            "seed-running-terminal",
            terminal_id,
            TerminalLifecycle::Running,
            Some(incarnation),
            None,
        )
        .unwrap();
    }
    tabs
}

/// A session whose store is [`registry_with_a_floating_pane`], with no daemon and no holder yet.
fn session(name: &'static str) -> Session {
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-{name}-{}", crate::workspace_registry::new_uuid_v4()));
    let mut tabs = registry_with_a_floating_pane(&root, name).into_iter();
    let tab = tabs.next().unwrap();
    let second_tab = tabs.next();
    let host_root = crate::terminal_host_runtime::terminal_host_root(&root, name);
    std::fs::create_dir_all(&host_root).unwrap();
    std::fs::set_permissions(&host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let socket = HolderService::socket_for_test(&host_root).unwrap();
    let _ = std::fs::remove_file(&socket);
    Session { name, root, host_root, socket, tab, second_tab }
}

/// Runs `sql` on the store of `session` while no daemon has it, as a build that stopped left it.
fn stage(session: &Session, sql: &str) -> anyhow::Result<()> {
    WorkspaceRegistry::open(&session.root, session.name).unwrap().execute_sql_for_test(sql)
}

/// The mark of a hidden quick terminal on the record of the floating pane, as this build writes it: the
/// focus goes back to the tiled pane.
fn mark_hidden(session: &Session) -> anyhow::Result<()> {
    stage(
        session,
        &format!(
            "UPDATE resource_floating_panes SET quick = 2, quick_from = '{}' WHERE pane_id = '{}'",
            tiled_pane(),
            floating_pane()
        ),
    )
}

/// The first column of the first record of `sql` in the store of the daemon that runs.
fn stored(mux: &Mux, sql: &str) -> String {
    mux.workspace_registry.lock().unwrap().query_text_for_test(sql).unwrap()
}

/// The columns of the table of floating panes, in their order.
fn columns(mux: &Mux) -> String {
    stored(
        mux,
        "SELECT group_concat(name, ',') FROM \
         (SELECT name FROM pragma_table_info('resource_floating_panes') ORDER BY cid)",
    )
}

/// Starts the daemon on `session` with a holder that lists one shell for each of the 2 terminals and answers
/// before the start asks. The shells: the tiled pane's, then the floating pane's.
fn start(session: &Session) -> (Arc<Mux>, StandIn, [KeptShell; 2]) {
    let holder = session.holder();
    let shells = [KeptShell::new(), KeptShell::new()];
    holder.order(Order::AnswerEach(vec![
        shells[0].listed_as(TERMINAL),
        shells[1].listed_as(SECOND_TERMINAL),
    ]));
    // The stand-in read the order: it answers a count only after it.
    assert_eq!(holder.connects(), 0);
    // The clock does not move in the start: no wait of the start ends by time.
    let clock = StepClock::new(Duration::ZERO, AT_START);
    let mux = session.start(&clock).unwrap();
    (mux, holder, shells)
}

/// The layout fields of the screen as a client reads them, and the ids of the tiled and of the floating pane.
fn screen(mux: &Mux) -> (Value, PaneId, PaneId) {
    mux.with_state(|state| {
        let pane = |public_id: PanePublicId| {
            state
                .panes
                .values()
                .find(|pane| pane.public_id == public_id)
                .map(|pane| pane.id)
                .unwrap()
        };
        (
            crate::server::screen_layout_json(
                &state.workspaces[0].screens[0],
                &state.resource_indexes.split_ids,
            ),
            pane(tiled_pane()),
            pane(floating_pane()),
        )
    })
}

/// The list `floating` of a screen whose one floating pane is `pane` at `FRAME`.
fn the_list(pane: PaneId) -> Value {
    let [x, y, w, h] = FRAME.fractions();
    serde_json::json!([{"pane": pane, "x": x, "y": y, "w": w, "h": h}])
}

/// What the start kept of `terminal`: the process of its runtime, its lifecycle, its incarnation, no recorded
/// end, and the `adopting` mark of its tab.
fn kept_shell(
    mux: &Mux,
    terminal: &str,
) -> (Option<u32>, TerminalLifecycle, Option<String>, bool, bool) {
    let resolved = mux.resolve_terminal(terminal).unwrap().unwrap();
    (
        resolved.surface.and_then(|id| mux.surface(id)).and_then(|surface| surface.process_id()),
        resolved.terminal.lifecycle,
        resolved.terminal.incarnation.clone(),
        resolved.terminal.exit.is_none(),
        mux.terminal_is_pending(terminal),
    )
}

/// `shell` as a start that attached it shows it: its process id, running, the incarnation of before the stop.
fn attached(
    shell: &KeptShell,
    incarnation: &str,
) -> (Option<u32>, TerminalLifecycle, Option<String>, bool, bool) {
    (
        Some(u32::try_from(shell.pid()).unwrap()),
        TerminalLifecycle::Running,
        Some(incarnation.into()),
        true,
        false,
    )
}

/// The start attached the shell of each pane, and each process still runs.
fn assert_the_shells_live(mux: &Mux, shells: &mut [KeptShell; 2]) {
    assert_eq!(
        (kept_shell(mux, TERMINAL), kept_shell(mux, SECOND_TERMINAL)),
        (attached(&shells[0], INCARNATION), attached(&shells[1], SECOND_INCARNATION)),
        "(process id, lifecycle, incarnation, no end, adopting mark) of the terminal of the tiled pane and \
         of the terminal of the floating pane: the start attached the process that the holder kept"
    );
    for shell in shells {
        assert!(shell.process.try_wait().unwrap().is_none(), "the shell {} ended", shell.pid());
    }
}

/// The harness of the tests below, with no mark: a start on a store with a floating pane attaches the shell
/// of each pane and keeps the list.
#[test]
fn a_start_attaches_the_shell_of_a_floating_pane() {
    let session = session("quick-terminal-floating-start");
    let (mux, holder, mut shells) = start(&session);
    let (layout, tiled, floating) = screen(&mux);
    assert_eq!(
        layout["floating"],
        the_list(floating),
        "the pane below floats at its frame: {layout}"
    );
    assert_eq!(layout["active_pane"], serde_json::json!(tiled), "{layout}");
    assert_the_shells_live(&mux, &mut shells);
    session.end(mux, holder);
}

/// A stop with a hidden quick terminal and a start: it is hidden still, it is the same pane with its frame,
/// the focus is not on it, and its shell is the process that ran before the stop.
#[test]
fn a_start_with_a_hidden_quick_terminal_keeps_it_hidden_with_its_shell() {
    let session = session("quick-terminal-hidden-start");
    let marked = mark_hidden(&session);
    assert!(marked.is_ok(), "the store takes the mark of a hidden quick terminal: {marked:?}");

    let (mux, holder, mut shells) = start(&session);
    let (layout, tiled, floating) = screen(&mux);
    assert_eq!(
        layout["quick_terminal"],
        serde_json::json!({"pane": floating, "hidden": true, "from": tiled}),
        "the quick terminal of the screen after the start: {layout}"
    );
    assert_eq!(
        layout["floating"],
        the_list(floating),
        "a hidden quick terminal keeps its frame: {layout}"
    );
    assert_eq!(
        layout["active_pane"],
        serde_json::json!(tiled),
        "the focus is not on a hidden pane"
    );
    assert_the_shells_live(&mux, &mut shells);
    assert_eq!(
        stored(
            &mux,
            &format!(
                "SELECT CAST(quick AS TEXT) || ' ' || quick_from FROM resource_floating_panes \
                 WHERE pane_id = '{}'",
                floating_pane()
            ),
        ),
        format!("2 {}", tiled_pane()),
        "the start left the mark in the store"
    );
    session.end(mux, holder);
}

/// A build before the mark wrote the list of a screen whose quick terminal was hidden: the quick terminal is
/// a plain floating pane that shows. No pane is lost and each shell lives.
#[test]
fn a_write_of_an_older_build_makes_the_quick_terminal_a_floating_pane_that_shows() {
    let session = session("quick-terminal-older-write");
    let marked = mark_hidden(&session);
    assert!(marked.is_ok(), "the store takes the mark of a hidden quick terminal: {marked:?}");
    // What an older build runs on the store: its statement for the table at an open, then its 2 statements
    // for the list of a screen (it deletes the screen's records and writes each with the 7 columns it knows).
    let FloatFrame { x, y, w, h } = FRAME;
    let older_build = stage(
        &session,
        &format!(
            "{TABLE_BEFORE_THE_MARK}
             DELETE FROM resource_floating_panes WHERE screen_id = '{screen}';
             INSERT INTO resource_floating_panes(screen_id, pane_id, position, x, y, w, h)
               VALUES('{screen}', '{pane}', 0, {x}, {y}, {w}, {h});",
            screen = the_screen(),
            pane = floating_pane(),
        ),
    );
    assert!(
        older_build.is_ok(),
        "the statements of an older build run on the store: {older_build:?}"
    );

    let (mux, holder, mut shells) = start(&session);
    let (layout, tiled, floating) = screen(&mux);
    assert_eq!(
        layout["quick_terminal"],
        Value::Null,
        "no quick terminal after the older write: {layout}"
    );
    assert_eq!(layout["floating"], the_list(floating), "the pane floats at its frame: {layout}");
    assert_eq!(layout["active_pane"], serde_json::json!(tiled), "{layout}");
    assert_eq!(mux.with_state(|state| state.panes.len()), 2, "each pane is a pane after the start");
    assert_the_shells_live(&mux, &mut shells);
    assert_eq!(
        stored(
            &mux,
            "SELECT group_concat(CAST(quick AS TEXT) || ' ' || coalesce(quick_from, 'none'), ',') \
             FROM resource_floating_panes",
        ),
        "0 none",
        "the record of the older write has no mark"
    );
    session.end(mux, holder);
}

/// A store that a build before the mark made (the table has no column of the mark): the start adds the 2
/// columns, and each floating pane is a plain floating pane.
#[test]
fn a_store_with_no_quick_column_opens_and_each_floating_pane_is_plain() {
    let session = session("quick-terminal-store-before");
    // The table and its record as a build before the mark left them. (The open that staged the store made
    // the table of this build.)
    let FloatFrame { x, y, w, h } = FRAME;
    stage(
        &session,
        &format!(
            "DROP TABLE resource_floating_panes;
             {TABLE_BEFORE_THE_MARK}
             INSERT INTO resource_floating_panes(screen_id, pane_id, position, x, y, w, h)
               VALUES('{screen}', '{pane}', 0, {x}, {y}, {w}, {h});",
            screen = the_screen(),
            pane = floating_pane(),
        ),
    )
    .unwrap();

    let (mux, holder, mut shells) = start(&session);
    assert_eq!(
        columns(&mux),
        "screen_id,pane_id,position,x,y,w,h,quick,quick_from",
        "the start adds the columns of the mark to a table that has none"
    );
    assert_eq!(
        stored(
            &mux,
            "SELECT group_concat(CAST(quick AS TEXT) || ' ' || coalesce(quick_from, 'none'), ',') \
             FROM resource_floating_panes",
        ),
        "0 none",
        "each record of the store of before has no mark"
    );
    let (layout, tiled, floating) = screen(&mux);
    assert_eq!(
        layout["quick_terminal"],
        Value::Null,
        "no quick terminal in a store of before: {layout}"
    );
    assert_eq!(layout["floating"], the_list(floating), "the pane floats at its frame: {layout}");
    assert_eq!(layout["active_pane"], serde_json::json!(tiled), "{layout}");
    assert_eq!(mux.with_state(|state| state.panes.len()), 2, "each pane is a pane after the start");
    assert_the_shells_live(&mux, &mut shells);
    session.end(mux, holder);
}
