//! `app-screens-v1` rules on the remaining paths, over the wire only:
//! tab-group moves, screen moves, new screens in an app workspace, layout
//! undo, `tab.create_app`'s revision precondition, new tabs sent to an app
//! workspace (its companion workspace), restart after a refusal, an
//! ordinary workspace whose only tab is an app tab, `workspace.create
//! {initial}`, the companion's name contract and the kind table rebuild.

use super::*;

/// Tab-group moves out of and into an app screen are refused.
#[test]
fn tab_group_moves_respect_the_app_screen() {
    let mut wire = Wire::new();
    let (_, _, app, app_pane, second, terminal_pane) = store_and_terminals(&mut wire);
    let before = layout_fingerprint(&wire.tree());
    let group = wire.ok(json!({"cmd": "create-tab-group", "surfaces": [app], "name": "App"}));
    let group = group["group"]["id"].as_str().unwrap().to_string();
    for request in [
        json!({"cmd": "move-tab-group", "group": group, "pane": terminal_pane, "index": 0}),
        json!({"cmd": "move-tab-group-to-split", "group": group, "pane": terminal_pane,
               "edge": "right"}),
        json!({"cmd": "move-tab-group-to-new-workspace", "group": group}),
    ] {
        wire.refused(request, "app-screen-fixed");
    }
    let other = wire.ok(json!({"cmd": "create-tab-group", "surfaces": [second], "name": "T"}));
    let other = other["group"]["id"].as_str().unwrap().to_string();
    wire.refused(
        json!({"cmd": "move-tab-group", "group": other, "pane": app_pane, "index": 0}),
        "app-screen-fixed",
    );
    let after = layout_fingerprint(&wire.tree());
    let tabs_of =
        |tree: &Value| screens(tree).iter().map(tabs).map(|t| t.len()).collect::<Vec<_>>();
    assert_eq!(tabs_of(&after), tabs_of(&before), "a refused group move moved a tab");
    wire.mux.shutdown();
}

/// An app workspace keeps exactly its one app screen: moving the app screen
/// out, a screen in, or creating a screen in it is refused.
#[test]
fn app_workspace_keeps_exactly_its_app_screen() {
    let mut wire = Wire::new();
    let (workspace, screen_id, _, app_pane, _, terminal_pane) = store_and_terminals(&mut wire);
    let app_workspace = wire.workspace_slot(&workspace);
    let (app_screen, terminal_workspace, terminal_screen) = wire.mux.with_state(|state| {
        let screen_of = |pane| {
            let (w, s) = state.screen_of(pane).unwrap();
            (state.workspaces[w].id, state.workspaces[w].screens[s].id)
        };
        let (_, app_screen) = screen_of(app_pane);
        let (terminal_workspace, terminal_screen) = screen_of(terminal_pane);
        (app_screen, terminal_workspace, terminal_screen)
    });
    // The app screen is its workspace's last screen: moving it out is
    // refused before the app rules are asked.
    for request in [
        json!({"cmd": "move-screen", "screen": app_screen, "workspace": terminal_workspace}),
        json!({"cmd": "move-screen", "screen": app_screen, "new_workspace": true}),
    ] {
        let response = wire.send(request.clone());
        assert_eq!(response["ok"], false, "{request}: {response}");
    }
    // A second screen, so the terminal workspace may give one away.
    wire.ok(json!({"cmd": "new-screen", "workspace": terminal_workspace}));
    for request in [
        json!({"cmd": "move-screen", "screen": terminal_screen, "workspace": app_workspace}),
        json!({"cmd": "new-screen", "workspace": app_workspace}),
    ] {
        wire.refused(request, "app-screen-fixed");
    }
    wire.v2_refused(
        "screen.create",
        json!({"workspace": workspace}),
        "screen-in-app-workspace",
        "app.screen_fixed",
    );
    let app_screens = screens(&wire.tree())
        .into_iter()
        .filter(|screen| screen["resource_id"] == screen_id.as_str())
        .count();
    assert_eq!(app_screens, 1);
    wire.mux.shutdown();
}

/// `tab.create_app` honors `expected_revision` like `tab.create_browser`.
#[test]
fn tab_create_app_honors_expected_revision() {
    let wire = Wire::new();
    let (_, pane) = wire.terminal_pane();
    let public_pane = wire.public_pane(pane);
    let ahead = wire.mux.with_state(|state| state.resource_revision) + 100;
    let stale = json!({"pane": public_pane, "app": STORE, "expected_revision": ahead.to_string()});
    wire.v2_refused("tab.create_app", stale, "create-stale", "revision.conflict");
    let revision = wire.mux.with_state(|state| state.resource_revision);
    let current =
        json!({"pane": public_pane, "app": STORE, "expected_revision": revision.to_string()});
    let created = wire.v2_ok("tab.create_app", current, Some("create-current"));
    assert_eq!(created["value"]["kind"], "app", "{created}");
    wire.mux.shutdown();
}

/// A refused op leaves the store as it was: after a restart the app screen
/// still has its one app tab.
#[test]
fn a_refused_op_survives_a_restart_unchanged() {
    let store = Store::new("refused-restart");
    let mut wire = store.open();
    let created = wire.ensure_app(STORE, "app", "open-store");
    let screen = created["value"]["screen_id"].as_str().unwrap().to_string();
    let (app, pane) = app_tab(&wire.screen(&screen));
    wire.refused(json!({"cmd": "close-surface", "surface": app}), "app-screen-fixed");
    wire.refused(json!({"cmd": "new-tab", "pane": pane}), "app-screen-fixed");
    let before = wire.public_tab(app);
    wire.mux.shutdown();
    drop(wire);
    let mut wire = store.open();
    let raw = wire.screen(&screen);
    assert_eq!(raw["kind"], "app", "{raw}");
    let (app, _) = app_tab(&raw);
    assert_eq!(wire.public_tab(app), before);
    wire.mux.shutdown();
}

/// Layout undo has nothing to restore on an app screen, and changes
/// nothing there.
#[test]
fn layout_undo_leaves_the_app_screen_as_it_is() {
    let mut wire = Wire::new();
    let store = wire.ensure_app(STORE, "app", "open-store");
    let (_, pane) = app_tab(&wire.screen(store["value"]["screen_id"].as_str().unwrap()));
    let before = layout_fingerprint(&wire.tree());
    let response = wire.send(json!({"cmd": "undo-layout", "pane": pane}));
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(layout_fingerprint(&wire.tree()), before);
    wire.mux.shutdown();
}

/// A new tab sent to an app workspace (workspace or screen target, not a
/// pane) is not refused: it goes to the app workspace's companion ordinary
/// workspace, created directly after it once. A pane inside the app screen
/// stays refused.
#[test]
fn new_tabs_sent_to_an_app_workspace_go_to_its_companion() {
    let mut wire = Wire::new();
    let home = wire.v2_ok("workspace.ensure_home", json!({"app": HOME}), Some("connect"));
    let home_id = home["value"]["workspace_id"].as_str().unwrap().to_string();
    let home_slot = wire.workspace_slot(&home_id);
    let screen = wire.mux.with_state(|state| {
        let workspace = state.workspace_by_id(home_slot).unwrap();
        workspace.screens[0].public_id.to_string()
    });
    let (app, app_pane) = app_tab(&wire.screen(&screen));
    assert!(companion_of(&wire, HOME).is_none());
    let conversation = wire.ok(json!({"cmd": "new-conversation-tab", "workspace": home_slot,
                                     "conversation": "conv_01X", "owner": "local",
                                     "origin": "route-test", "mutation_id": "r0"}));
    let companion = companion_of(&wire, HOME).expect("the companion was created");
    let workspace_of = |wire: &Wire, surface: SurfaceId| {
        wire.mux.with_state(|state| {
            let (w, _) = state.screen_of(state.pane_of(surface).unwrap()).unwrap();
            state.workspaces[w].public_id.to_string()
        })
    };
    assert_eq!(workspace_of(&wire, conversation["surface"].as_u64().unwrap()), companion);
    let browser = wire.v2_ok(
        "tab.create_browser",
        json!({"workspace": home_id, "screen": screen, "url": "https://example.com"}),
        Some("screen-target"),
    );
    assert_eq!(browser["value"]["workspace_id"], companion.as_str(), "{browser}");
    let app_tab_created =
        wire.ok(json!({"cmd": "new-app-tab", "workspace": home_slot, "app": STORE}));
    assert_eq!(workspace_of(&wire, app_tab_created["surface"].as_u64().unwrap()), companion);
    assert_eq!(companion_of(&wire, HOME), Some(companion.clone()), "one companion");
    // A rename by the user is final, and the marker (not the name) finds
    // the companion.
    wire.v2_ok("workspace.rename", json!({"workspace": companion, "name": "Mine"}), Some("rename"));
    let again = wire.ok(json!({"cmd": "new-app-tab", "workspace": home_slot, "app": STORE}));
    assert_eq!(workspace_of(&wire, again["surface"].as_u64().unwrap()), companion);
    let raw = wire.tree()["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["resource_id"] == companion.as_str())
        .cloned()
        .unwrap();
    assert_eq!((raw["name"].as_str(), raw["kind"].as_str()), (Some("Mine"), Some("app_tabs")));
    let order = wire.v2_ok("workspace.placement.list", json!({}), None);
    assert_eq!(order[1]["workspace"]["workspace_id"], companion.as_str(), "{order}");
    // The app screen is unchanged; a pane target inside it is refused.
    assert_eq!(app_tab(&wire.screen(&screen)), (app, app_pane));
    wire.refused(json!({"cmd": "new-tab", "pane": app_pane}), "app-screen-fixed");
    wire.v2_refused(
        "tab.create_terminal",
        json!({"workspace": home_id, "screen": screen, "pane": wire.public_pane(app_pane)}),
        "pane-target",
        "app.screen_fixed",
    );
    wire.mux.shutdown();
}

/// v2 `pane.swap` and `workspace.layout.apply` refuse the app screen.
#[test]
fn v2_swap_and_layout_apply_refuse_the_app_screen() {
    let mut wire = Wire::new();
    let (_, terminal_pane) = wire.terminal_pane();
    let created = wire.ensure_app(STORE, "app", "open-store");
    let screen = created["value"]["screen_id"].as_str().unwrap().to_string();
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let (_, app_pane) = app_tab(&wire.screen(&screen));
    let before = layout_fingerprint(&wire.tree());
    let other = wire.destination(terminal_pane);
    let swap = json!({"workspace": workspace, "screen": screen,
                      "pane": wire.public_pane(app_pane),
                      "other_workspace": other["destination_workspace"],
                      "other_screen": other["destination_screen"],
                      "other_pane": other["destination_pane"]});
    wire.v2_refused("pane.swap", swap, "swap-app", "app.screen_fixed");
    let layout =
        wire.v2_ok("screen.layout.export", json!({"workspace": workspace, "screen": screen}), None);
    let apply = json!({"workspace": workspace, "layout": layout});
    wire.v2_refused("workspace.layout.apply", apply, "apply-app", "app.screen_fixed");
    assert_eq!(layout_fingerprint(&wire.tree()), before);
    wire.mux.shutdown();
}

/// R91: an ordinary workspace whose only tab is an app tab (a first-party
/// page with its client state in `route`, up to 4 KiB) is valid, and the
/// tab and its route survive a restart.
#[test]
fn ordinary_workspace_with_only_an_app_tab_survives_a_restart() {
    let store = Store::new("only-app-tab");
    let wire = store.open();
    let created = wire.v2_ok(
        "workspace.create",
        json!({"name": "New Tab", "initial_content": "empty"}),
        Some("new-tab-workspace"),
    );
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let route = "s".repeat(4096);
    let tab = wire.v2_ok(
        "tab.create_app",
        json!({"workspace": workspace, "app": "cmux.agent", "route": route}),
        Some("agent-page"),
    );
    let tab_id = tab["value"]["tab_id"].as_str().unwrap().to_string();
    let too_long = json!({"workspace": workspace, "app": "cmux.agent", "route": "s".repeat(4097)});
    let refused = wire.v2("tab.create_app", too_long, Some("agent-page-long"));
    assert_eq!(refused["ok"], false, "{refused}");
    wire.mux.shutdown();
    drop(wire);

    let mut wire = store.open();
    let tree = wire.tree();
    let workspace = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["resource_id"] == workspace.as_str())
        .cloned()
        .expect("the workspace with only an app tab is kept");
    assert_eq!(workspace["kind"], "normal", "{workspace}");
    let tabs = tabs(&workspace["screens"][0]);
    assert_eq!(tabs.len(), 1, "{workspace}");
    assert_eq!(tabs[0]["tab_resource_id"], tab_id.as_str());
    assert_eq!(tabs[0]["kind"], "app");
    assert_eq!(tabs[0]["app"], "cmux.agent");
    assert_eq!(tabs[0]["route"].as_str().map(str::len), Some(4096));
    wire.mux.shutdown();
}

/// R91: `workspace.create {initial_content: "app", initial}` (and raw
/// `create-workspace {initial}`) makes a workspace whose only tab is an app
/// tab in ONE commit and one event batch, so no client sees it empty; a
/// retry replays it and it survives a restart.
#[test]
fn workspace_create_with_an_initial_app_tab_is_one_commit() {
    let store = Store::new("initial-app");
    let mut wire = store.open();
    let before = wire.mux.with_state(|state| state.resource_revision);
    let params = json!({"name": "New Tab", "initial_content": "app",
                        "initial": {"app": "cmux.agent", "route": "r1"}});
    let created = wire.v2_ok("workspace.create", params.clone(), Some("new-tab-1"));
    assert_eq!(created["value"]["kind"], "app", "{created}");
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let tab_id = created["value"]["tab_id"].as_str().unwrap().to_string();
    let batches = wire.mux.resource_events_after(before).unwrap().batches;
    assert_eq!(batches.len(), 1, "the creation committed more than once");
    let changes = batches[0].changes.as_array().unwrap();
    for (resource, id) in [("workspace", workspace.as_str()), ("tab", tab_id.as_str())] {
        assert!(
            changes.iter().any(|change| change["resource"] == resource && change["id"] == id),
            "the batch lacks the {resource}: {changes:?}"
        );
    }
    let again = wire.v2_ok("workspace.create", params, Some("new-tab-1"));
    assert_eq!(
        (again["replayed"].as_bool(), again["value"]["tab_id"].as_str()),
        (Some(true), Some(tab_id.as_str()))
    );
    wire.v2_refused(
        "workspace.create",
        json!({"initial_content": "empty", "initial": {"app": "cmux.agent"}}),
        "initial-empty",
        "validation.invalid",
    );
    wire.v2_refused(
        "workspace.create",
        json!({"initial_content": "app"}),
        "app-bare",
        "validation.invalid",
    );
    let raw = wire.ok(json!({"cmd": "create-workspace", "name": "Raw",
                             "initial": {"app": "cmux.agent", "route": "r2"}}));
    let raw_key = raw["key"].as_str().unwrap().to_string();
    assert!(raw["surface"].as_u64().is_some(), "{raw}");
    let only_tab = |tree: &Value, matches: &dyn Fn(&Value) -> bool| {
        let workspaces = tree["workspaces"].as_array().unwrap();
        let workspace = workspaces.iter().find(|item| matches(item)).cloned().unwrap();
        let tabs =
            workspace["screens"].as_array().unwrap().iter().flat_map(tabs).collect::<Vec<_>>();
        assert_eq!(tabs.len(), 1, "{workspace}");
        (workspace["kind"].clone(), tabs[0].clone())
    };
    let (_, raw_tab) = only_tab(&wire.tree(), &|item| item["key"] == raw_key.as_str());
    assert_eq!((raw_tab["kind"].as_str(), raw_tab["route"].as_str()), (Some("app"), Some("r2")));
    wire.mux.shutdown();
    drop(wire);

    let mut wire = store.open();
    let (kind, tab) = only_tab(&wire.tree(), &|item| item["resource_id"] == workspace.as_str());
    assert_eq!(kind, "normal");
    assert_eq!(tab["tab_resource_id"], tab_id.as_str());
    assert_eq!((tab["kind"].as_str(), tab["route"].as_str()), (Some("app"), Some("r1")));
    wire.mux.shutdown();
}

/// `workspace.ensure_app` never shows its workspace empty: the commit that
/// creates the workspace also creates its app tab.
#[test]
fn ensure_app_creates_its_workspace_with_the_app_tab() {
    let wire = Wire::new();
    let before = wire.mux.with_state(|state| state.resource_revision);
    let created = wire.ensure_app(STORE, "app", "open-store");
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let batches = wire.mux.resource_events_after(before).unwrap().batches;
    let first = batches
        .iter()
        .find(|batch| {
            batch.changes.as_array().unwrap().iter().any(|change| {
                change["resource"] == "workspace" && change["id"] == workspace.as_str()
            })
        })
        .expect("a batch creates the workspace");
    let changes = first.changes.as_array().unwrap();
    assert!(
        changes.iter().any(|change| change["resource"] == "tab" && change["kind"] == "upsert"),
        "the app workspace appeared without its tab: {changes:?}"
    );
    wire.mux.shutdown();
}

/// The companion's name contract: the daemon names it "<display_name>
/// Tabs" (the client-sent English app name, else the app id) and reports
/// `extra.default_title: true` until any rename, which turns it false for
/// good (also after a restart and after renaming back).
#[test]
fn companion_default_title_turns_false_on_rename_for_good() {
    let store = Store::new("companion-title");
    let mut wire = store.open();
    let home = wire.v2_ok("workspace.ensure_home", json!({}), Some("connect-1"));
    let home_slot = wire.workspace_slot(home["value"]["workspace_id"].as_str().unwrap());
    wire.ok(json!({"cmd": "new-conversation-tab", "workspace": home_slot,
                   "conversation": "conv_01T", "owner": "local",
                   "origin": "title-test", "mutation_id": "t0"}));
    let migrate = json!({"app": HOME, "display_name": "Home"});
    wire.v2_ok("workspace.ensure_home", migrate, Some("connect-2"));
    let companion = companion_of(&wire, HOME).expect("the migration made the companion");
    let extra = |wire: &Wire| {
        let snapshot = wire.snapshot();
        let workspaces = snapshot["workspaces"].as_array().unwrap();
        workspaces.iter().find(|item| item["id"] == companion.as_str()).cloned().unwrap()
    };
    let raw_extra = |wire: &mut Wire| {
        let tree = wire.tree();
        let workspaces = tree["workspaces"].as_array().unwrap();
        let raw = workspaces.iter().find(|item| item["resource_id"] == companion.as_str());
        let raw = raw.cloned().unwrap();
        assert_eq!((raw["kind"].as_str(), raw["app"].as_str()), (Some("app_tabs"), Some(HOME)));
        raw["extra"]["default_title"].clone()
    };
    assert_eq!(raw_extra(&mut wire), true);
    let created = extra(&wire);
    assert_eq!(created["name"], "Home Tabs", "{created}");
    assert_eq!(created["extra"]["kind"], "app_tabs", "{created}");
    assert_eq!(created["extra"]["default_title"], true, "{created}");
    wire.v2_ok("workspace.rename", json!({"workspace": companion, "name": "Mine"}), Some("r1"));
    assert_eq!(extra(&wire)["extra"]["default_title"], false);
    assert_eq!(raw_extra(&mut wire), false);
    wire.v2_ok(
        "workspace.rename",
        json!({"workspace": companion, "name": "Home Tabs"}),
        Some("r2"),
    );
    assert_eq!(extra(&wire)["extra"]["default_title"], false, "renaming back keeps it false");
    assert_eq!(raw_extra(&mut wire), false, "renaming back keeps it false");

    // An app with a recorded display name names its companion after it.
    let store_app = wire.v2_ok(
        "workspace.ensure_app",
        json!({"app": STORE, "kind": "app", "display_name": "App Store"}),
        Some("open-store"),
    );
    let store_slot = wire.workspace_slot(store_app["value"]["workspace_id"].as_str().unwrap());
    wire.ok(json!({"cmd": "new-app-tab", "workspace": store_slot, "app": "cmux.agent"}));
    let store_companion = companion_of(&wire, STORE).expect("a new tab made the companion");
    let raw = wire.tree()["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["resource_id"] == store_companion.as_str())
        .cloned()
        .unwrap();
    assert_eq!(raw["name"], "App Store Tabs", "{raw}");
    assert_eq!((raw["kind"].as_str(), raw["app"].as_str()), (Some("app_tabs"), Some(STORE)));
    wire.mux.shutdown();
    drop(wire);

    let mut wire = store.open();
    assert_eq!(raw_extra(&mut wire), false);
    let restarted = extra(&wire);
    assert_eq!(restarted["extra"]["kind"], "app_tabs", "{restarted}");
    assert_eq!(restarted["extra"]["default_title"], false, "{restarted}");
    wire.mux.shutdown();
}

/// A new tab sent to an app workspace without a companion makes the
/// companion in the same commit as the tab: one event batch holds the
/// workspace (kind `app_tabs`) and the tab, so no reader sees it empty.
#[test]
fn a_routed_new_tab_creates_its_companion_in_one_commit() {
    let mut wire = Wire::new();
    let created = wire.ensure_app(STORE, "app", "open-store");
    let store_slot = wire.workspace_slot(created["value"]["workspace_id"].as_str().unwrap());
    let before = wire.mux.with_state(|state| state.resource_revision);
    let tab = wire.ok(json!({"cmd": "new-app-tab", "workspace": store_slot, "app": "cmux.agent"}));
    let tab_id = tab["tab_resource_id"].as_str().unwrap().to_string();
    let companion = companion_of(&wire, STORE).expect("the new tab made the companion");
    let batches = wire.mux.resource_events_after(before).unwrap().batches;
    let first = batches
        .iter()
        .find(|batch| {
            batch.changes.as_array().unwrap().iter().any(|change| {
                change["resource"] == "workspace" && change["id"] == companion.as_str()
            })
        })
        .expect("a batch creates the companion");
    let changes = first.changes.as_array().unwrap();
    assert!(
        changes.iter().any(|change| change["resource"] == "workspace"
            && change["id"] == companion.as_str()
            && change["value"]["extra"]["kind"] == "app_tabs"),
        "the companion appeared without its kind: {changes:?}"
    );
    assert!(
        changes.iter().any(|change| change["resource"] == "tab" && change["id"] == tab_id.as_str()),
        "the companion appeared without its tab: {changes:?}"
    );
    wire.mux.shutdown();
}

/// The registry database file under a store root.
fn registry_file(root: &Path) -> PathBuf {
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else if path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3") {
                return path;
            }
        }
    }
    panic!("no registry under {}", root.display());
}

/// A registry whose kind table has the shape of builds before `app_tabs`
/// (kind CHECK = 'home', a plain unique index on `kind`) is rebuilt at
/// open, in one transaction: the home row is kept, the second open changes
/// nothing, a companion can then be stored, and a second home is refused.
#[test]
fn workspace_kind_table_of_an_older_build_is_rebuilt_at_open() {
    let store = Store::new("kind-migration");
    let wire = store.open();
    let home = wire.v2_ok("workspace.ensure_home", json!({}), Some("connect-1"));
    let home_id = home["value"]["workspace_id"].as_str().unwrap().to_string();
    wire.mux.shutdown();
    drop(wire);
    let path = registry_file(&store.root);
    {
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "DROP TABLE workspace_kind;
                 CREATE TABLE workspace_kind (
                   workspace_id TEXT PRIMARY KEY NOT NULL,
                   kind TEXT NOT NULL CHECK(kind = 'home')
                 );
                 CREATE UNIQUE INDEX workspace_kind_one_home ON workspace_kind(kind);",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO workspace_kind(workspace_id, kind) VALUES(?1, 'home')",
                [&home_id],
            )
            .unwrap();
    }
    let schema = |path: &Path| -> (Vec<String>, Vec<(String, String)>) {
        let connection = rusqlite::Connection::open(path).unwrap();
        let columns = connection
            .prepare("SELECT name FROM pragma_table_info('workspace_kind')")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        let rows = connection
            .prepare("SELECT workspace_id, kind FROM workspace_kind ORDER BY kind")
            .unwrap()
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        (columns, rows)
    };

    let mut wire = store.open();
    let home_slot = wire.workspace_slot(&home_id);
    let raw_home = wire.tree()["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["resource_id"] == home_id.as_str())
        .cloned()
        .unwrap();
    assert_eq!(raw_home["kind"], "home", "{raw_home}");
    wire.ok(json!({"cmd": "new-conversation-tab", "workspace": home_slot,
                   "conversation": "conv_01M", "owner": "local",
                   "origin": "kind-test", "mutation_id": "m0"}));
    let migrate = json!({"app": HOME, "display_name": "Home"});
    wire.v2_ok("workspace.ensure_home", migrate, Some("connect-2"));
    let companion = companion_of(&wire, HOME).expect("the rebuilt table holds the companion");
    wire.mux.shutdown();
    drop(wire);
    let (columns, rows) = schema(&path);
    for column in ["workspace_id", "kind", "app_id", "workspace_key", "default_name", "renamed"] {
        assert!(columns.iter().any(|name| name == column), "{column} missing: {columns:?}");
    }
    let expected = vec![(companion.clone(), "app_tabs".to_string()), (home_id, "home".to_string())];
    assert_eq!(rows, expected);

    // The second open (and a restart) changes nothing.
    let wire = store.open();
    assert_eq!(companion_of(&wire, HOME), Some(companion));
    wire.mux.shutdown();
    drop(wire);
    assert_eq!(schema(&path), (columns, expected));
    let connection = rusqlite::Connection::open(&path).unwrap();
    let second_home = connection
        .execute("INSERT INTO workspace_kind(workspace_id, kind) VALUES('ws_x', 'home')", []);
    assert!(second_home.is_err(), "the one-home index survived the rebuild");
}
