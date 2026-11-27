//! The registry open checks the foreign keys of the state tables once, and
//! its topology checks compile a fixed number of statements.
//!
//! An open of an existing registry ran the foreign key check 2 times, and
//! `validate_resource_invariants` ran 11 statements for each live workspace
//! with one screen, pane, tab and terminal, each compiled at its call. These
//! tests count calls and compiled statements (no wall clock). They also hold
//! the message of each rule of the per-row loops, so the reads behind the
//! rules can change and the refusals cannot.
//!
//! One rule of the loops has no fixture: `tab ... content ... has identity
//! kind ...`. The identity check before the loops refuses each terminal or
//! browser row whose identity is absent, of a different kind or not live,
//! and the rule before it in the loop needs that row live.

use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use serde_json::json;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-open-invariants-{label}-{}", new_uuid_v4()))
}

fn workspace_id(index: u64) -> WorkspacePublicId {
    WorkspacePublicId::parse(format!("ws_{:032x}", index + 1)).unwrap()
}

fn workspace_key(index: u64) -> String {
    format!("workspace-{index}")
}

fn screen_id(index: u64) -> ScreenPublicId {
    ScreenPublicId::parse(format!("screen_{:032x}", index + 1)).unwrap()
}

fn pane_id(index: u64) -> PanePublicId {
    PanePublicId::parse(format!("pane_{:032x}", index + 1)).unwrap()
}

fn tab_id(index: u64) -> TabPublicId {
    TabPublicId::parse(format!("tab_{:032x}", index + 1)).unwrap()
}

fn terminal_id(index: u64) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{:032x}", index + 1)).unwrap()
}

/// The id of the terminal's host row (a UUIDv4 in hex).
fn host_id(index: u64) -> String {
    format!("0000000000004000a{:015x}", index + 1)
}

/// `count` live workspaces, each with one screen, one pane, one tab and one
/// terminal with its host row. Workspace 0 is the active one.
fn registry_with_workspaces(count: u64) -> WorkspaceRegistry {
    let mut registry = WorkspaceRegistry::in_memory("open-invariants").unwrap();
    let mut changes = Vec::new();
    for index in 0..count {
        let workspace = RegistryWorkspace {
            id: index + 1,
            public_id: workspace_id(index),
            key: workspace_key(index),
            name: "Workspace".into(),
            name_source: Default::default(),
            name_revision: 0,
            group_key: "default".into(),
        };
        changes.push(ResourceChange::UpsertWorkspace {
            workspace,
            position: usize::try_from(index).unwrap(),
            active_screen: Some(screen_id(index)),
        });
        changes.push(ResourceChange::UpsertScreen(RegistryScreen {
            public_id: screen_id(index),
            workspace_id: workspace_id(index),
            position: 0,
            name: Some("Main".into()),
            layout: RegistryLayoutNode::Leaf { pane: pane_id(index) },
            active_pane: pane_id(index),
            zoomed_pane: None,
            auto_layout: None,
            viewport: RegistryViewport::default(),
        }));
        changes.push(ResourceChange::UpsertPane(RegistryPane {
            public_id: pane_id(index),
            screen_id: screen_id(index),
            name: Some("Shell".into()),
            active_tab: Some(tab_id(index)),
            creation_ordinal: index + 1,
        }));
        changes.push(ResourceChange::UpsertTerminal {
            public_id: terminal_id(index),
            terminal: RegistryTerminal {
                terminal_id: host_id(index),
                workspace_key: workspace_key(index),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: json!({"command":["/bin/zsh"],"cwd":"/tmp","rows":24,"cols":80}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
        });
        changes.push(ResourceChange::UpsertTab(RegistryTab {
            name_source: Default::default(),
            name_revision: 0,
            public_id: tab_id(index),
            pane_id: pane_id(index),
            position: 0,
            content_id: ContentPublicId::Terminal(terminal_id(index)),
            name: Some("zsh".into()),
            browser_url: None,
            terminal_id: Some(host_id(index)),
        }));
    }
    changes.push(ResourceChange::SetWorkspaceOrder {
        workspace_ids: (0..count).map(workspace_id).collect(),
    });
    for index in 0..count {
        changes.push(ResourceChange::SetScreenOrder {
            workspace_id: workspace_id(index),
            screen_ids: vec![screen_id(index)],
        });
        changes.push(ResourceChange::SetTabOrder {
            pane_id: pane_id(index),
            tab_ids: vec![tab_id(index)],
        });
    }
    changes.push(ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace_id(0)) });
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon("create-all", "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","count":count}),
            None,
            Some(0),
            &ResourcePatch { changes },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    registry
}

/// Run one statement that must change exactly one row.
fn change_one_row(registry: &WorkspaceRegistry, statement: &str, values: &[&str]) {
    let changed = registry
        .connection
        .get()
        .execute(statement, rusqlite::params_from_iter(values))
        .unwrap_or_else(|error| panic!("{statement}: {error}"));
    assert_eq!(changed, 1, "{statement} changed {changed} rows");
}

/// Close the row `id` of `table` and its identity, as a tombstone does.
fn close_row(registry: &WorkspaceRegistry, table: &str, id: &str) {
    let also = match table {
        "resource_screens" => ", position = NULL",
        "resource_terminals" => ", lifecycle = 'tombstoned'",
        _ => "",
    };
    change_one_row(
        registry,
        &format!("UPDATE {table} SET deleted_revision = 1{also} WHERE public_id = ?1"),
        &[id],
    );
    change_one_row(
        registry,
        "UPDATE resource_identities SET deleted_revision = 1 WHERE public_id = ?1",
        &[id],
    );
}

/// Let the next statements write a row that a CHECK of its table forbids.
fn ignore_check_constraints(registry: &WorkspaceRegistry) {
    registry.connection.get().execute_batch("PRAGMA ignore_check_constraints=ON;").unwrap();
}

fn validate(registry: &WorkspaceRegistry) -> anyhow::Result<()> {
    let db = registry.connection.get();
    let transaction = db.unchecked_transaction()?;
    validate_resource_invariants(&transaction)?;
    transaction.commit()?;
    Ok(())
}

/// The words with which the open's topology checks refuse `registry`.
fn refusal(registry: &WorkspaceRegistry) -> String {
    validate(registry).expect_err("the checks accepted a bad row").to_string()
}

/// SELECT statements that `validate_resource_invariants` compiles on
/// `registry`, sub-selects included.
fn compiled_selects(registry: &WorkspaceRegistry) -> u64 {
    let selects = Arc::new(AtomicU64::new(0));
    let counter = Arc::clone(&selects);
    registry
        .connection
        .get()
        .authorizer(Some(move |context: AuthContext<'_>| {
            if matches!(context.action, AuthAction::Select) {
                counter.fetch_add(1, Ordering::Relaxed);
            }
            Authorization::Allow
        }))
        .unwrap();
    let result = validate(registry);
    registry.connection.get().authorizer(None::<fn(AuthContext<'_>) -> Authorization>).unwrap();
    result.unwrap();
    selects.load(Ordering::Relaxed)
}

fn foreign_key_checks() -> usize {
    schema::state_foreign_key_checks_on_this_thread()
}

/// The topology checks compile the same number of statements for 10 and for
/// 100 workspaces. They compiled 11 more for each workspace: a daemon with
/// some hundreds of workspaces spent most of this open step in the SQL
/// compiler.
#[test]
fn open_invariants_compile_a_fixed_number_of_statements() {
    let small = compiled_selects(&registry_with_workspaces(10));
    let large = compiled_selects(&registry_with_workspaces(100));
    assert!(small > 0, "the authorizer counted no statement");
    assert_eq!(
        small, large,
        "the checks compiled {small} SELECT statements for 10 workspaces and {large} for 100"
    );
}

/// A reopen of a registry file checks the foreign keys of the state tables
/// once. It checked them 2 times: after the migrations and again in the
/// topology checks, with nothing between them that can break a key.
#[test]
fn open_invariants_reopen_checks_foreign_keys_once() {
    let root = temp_root("reopen-key-check");
    drop(WorkspaceRegistry::open(&root, "session").unwrap());
    let before = foreign_key_checks();
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(foreign_key_checks() - before, 1, "foreign key checks in one reopen");
    drop(registry);
    let _ = fs::remove_dir_all(root);
}

/// The first open of a new registry file checks the foreign keys once too.
#[test]
fn open_invariants_first_open_checks_foreign_keys_once() {
    let root = temp_root("first-key-check");
    let before = foreign_key_checks();
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(foreign_key_checks() - before, 1, "foreign key checks in a first open");
    drop(registry);
    let _ = fs::remove_dir_all(root);
}

/// The words with which SQLite refuses a pane whose identity and screen do
/// not exist.
fn insert_pane_of_no_screen(registry: &WorkspaceRegistry) -> String {
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO resource_panes(
               public_id, screen_id, creation_ordinal, created_revision, updated_revision
             ) VALUES(?1, ?2, 1, 1, 1)",
            params![pane_id(900).as_str(), screen_id(900).as_str()],
        )
        .expect_err("SQLite took a pane whose identity and screen do not exist")
        .to_string()
}

/// After an open, first or not, SQLite itself refuses a row whose key names
/// no parent: the open leaves foreign keys on.
#[test]
fn open_invariants_leave_foreign_keys_on() {
    let root = temp_root("keys-on");
    for open in ["first open", "reopen"] {
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let error = insert_pane_of_no_screen(&registry);
        assert!(error.contains("FOREIGN KEY constraint failed"), "{open}: {error}");
        drop(registry);
    }
    let _ = fs::remove_dir_all(root);
}

/// The same after an open that migrates: the open turns foreign keys off for
/// the migrations of a file with an older schema number, checks the keys once
/// and leaves them on. The file here has the tables of this build and the
/// number 13, as the other migration tests of this crate make it. It is not a
/// file that an older build wrote.
#[test]
fn open_invariants_leave_foreign_keys_on_after_a_migration() {
    let root = temp_root("keys-on-migrated");
    {
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        change_one_row(
            &registry,
            "UPDATE meta SET value = '13' WHERE key = 'schema_version' AND value = ?1",
            &[SCHEMA_VERSION.to_string().as_str()],
        );
    }
    let before = foreign_key_checks();
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(foreign_key_checks() - before, 1, "foreign key checks in a migrating open");
    assert_eq!(
        required_meta(&registry.connection.get(), "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    let error = insert_pane_of_no_screen(&registry);
    assert!(error.contains("FOREIGN KEY constraint failed"), "{error}");
    drop(registry);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn open_invariants_accept_the_fixture() {
    validate(&registry_with_workspaces(2)).unwrap();
}

#[test]
fn open_invariants_refuse_an_active_screen_of_another_workspace() {
    let registry = registry_with_workspaces(2);
    change_one_row(
        &registry,
        "UPDATE resource_workspaces SET active_screen_id = ?1 WHERE public_id = ?2",
        &[screen_id(0).as_str(), workspace_id(1).as_str()],
    );
    assert_eq!(
        refusal(&registry),
        format!(
            "workspace {} selects screen {} owned by {:?}",
            workspace_id(1),
            screen_id(0),
            Some(workspace_id(0).as_str())
        )
    );
}

#[test]
fn open_invariants_refuse_screens_with_no_active_screen() {
    let registry = registry_with_workspaces(2);
    change_one_row(
        &registry,
        "UPDATE resource_workspaces SET active_screen_id = NULL WHERE public_id = ?1",
        &[workspace_id(1).as_str()],
    );
    assert_eq!(
        refusal(&registry),
        format!("workspace {} has screens but no active screen", workspace_id(1))
    );
}

#[test]
fn open_invariants_refuse_a_screen_of_a_closed_workspace() {
    let registry = registry_with_workspaces(2);
    close_row(&registry, "resource_workspaces", workspace_id(1).as_str());
    change_one_row(
        &registry,
        "UPDATE workspaces SET tombstoned = 1, position = NULL, deleted_revision = 1
         WHERE workspace_key = ?1",
        &[workspace_key(1).as_str()],
    );
    assert_eq!(
        refusal(&registry),
        format!("screen {} has closed workspace {}", screen_id(1), workspace_id(1))
    );
}

#[test]
fn open_invariants_refuse_a_layout_that_differs_from_the_pane_rows() {
    let registry = registry_with_workspaces(2);
    close_row(&registry, "resource_panes", pane_id(1).as_str());
    assert_eq!(
        refusal(&registry),
        format!("screen {} layout does not match its live pane rows", screen_id(1))
    );
}

#[test]
fn open_invariants_refuse_an_active_pane_outside_the_layout() {
    let registry = registry_with_workspaces(2);
    change_one_row(
        &registry,
        "UPDATE resource_screens SET active_pane_id = ?1 WHERE public_id = ?2",
        &[pane_id(0).as_str(), screen_id(1).as_str()],
    );
    assert_eq!(
        refusal(&registry),
        format!("screen {} selects a pane outside its layout", screen_id(1))
    );
}

/// Workspace 1 with its screen closed and no active screen.
fn close_screen_of_workspace_one(registry: &WorkspaceRegistry) {
    close_row(registry, "resource_screens", screen_id(1).as_str());
    change_one_row(
        registry,
        "UPDATE resource_workspaces SET active_screen_id = NULL WHERE public_id = ?1",
        &[workspace_id(1).as_str()],
    );
}

#[test]
fn open_invariants_refuse_a_pane_of_a_closed_screen() {
    let registry = registry_with_workspaces(2);
    close_screen_of_workspace_one(&registry);
    assert_eq!(
        refusal(&registry),
        format!("pane {} has closed screen {}", pane_id(1), screen_id(1))
    );
}

#[test]
fn open_invariants_refuse_an_active_tab_of_another_pane() {
    let registry = registry_with_workspaces(2);
    change_one_row(
        &registry,
        "UPDATE resource_panes SET active_tab_id = ?1 WHERE public_id = ?2",
        &[tab_id(0).as_str(), pane_id(1).as_str()],
    );
    assert_eq!(
        refusal(&registry),
        format!(
            "pane {} selects tab {} owned by {:?}",
            pane_id(1),
            tab_id(0),
            Some(pane_id(0).as_str())
        )
    );
}

#[test]
fn open_invariants_refuse_tabs_with_no_active_tab() {
    let registry = registry_with_workspaces(2);
    change_one_row(
        &registry,
        "UPDATE resource_panes SET active_tab_id = NULL WHERE public_id = ?1",
        &[pane_id(1).as_str()],
    );
    assert_eq!(refusal(&registry), format!("pane {} has tabs but no active tab", pane_id(1)));
}

#[test]
fn open_invariants_refuse_a_tab_of_a_closed_pane() {
    let registry = registry_with_workspaces(2);
    close_screen_of_workspace_one(&registry);
    close_row(&registry, "resource_panes", pane_id(1).as_str());
    assert_eq!(refusal(&registry), format!("tab {} has closed pane {}", tab_id(1), pane_id(1)));
}

#[test]
fn open_invariants_refuse_an_invalid_content_kind() {
    let registry = registry_with_workspaces(2);
    ignore_check_constraints(&registry);
    change_one_row(
        &registry,
        "UPDATE resource_tabs SET content_kind = 'widget' WHERE public_id = ?1",
        &[tab_id(1).as_str()],
    );
    assert_eq!(
        refusal(&registry),
        format!("tab {} has invalid content kind {:?}", tab_id(1), "widget")
    );
}

#[test]
fn open_invariants_refuse_a_tab_of_a_closed_terminal() {
    let registry = registry_with_workspaces(2);
    close_row(&registry, "resource_terminals", terminal_id(1).as_str());
    assert_eq!(
        refusal(&registry),
        format!("tab {} references closed terminal {}", tab_id(1), terminal_id(1))
    );
}

/// A tab that shows a browser whose row and identity are closed. The other
/// fixtures show terminals only.
#[test]
fn open_invariants_refuse_a_tab_of_a_closed_browser() {
    let registry = registry_with_workspaces(2);
    let browser = format!("browser_{:032x}", 1);
    change_one_row(
        &registry,
        "INSERT INTO resource_identities(
           public_id, kind, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, 'browser', 1, 1, 1)",
        &[browser.as_str()],
    );
    change_one_row(
        &registry,
        "INSERT INTO resource_browsers(
           public_id, url, metadata_json, lifecycle,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, 'about:blank', '{}', 'tombstoned', 1, 1, 1)",
        &[browser.as_str()],
    );
    change_one_row(
        &registry,
        "UPDATE resource_tabs SET content_kind = 'browser', content_id = ?1 WHERE public_id = ?2",
        &[browser.as_str(), tab_id(1).as_str()],
    );
    assert_eq!(
        refusal(&registry),
        format!("tab {} references closed browser {browser}", tab_id(1))
    );
}

#[test]
fn open_invariants_refuse_a_live_terminal_that_is_not_active() {
    let registry = registry_with_workspaces(2);
    ignore_check_constraints(&registry);
    change_one_row(
        &registry,
        "UPDATE resource_terminals SET lifecycle = 'tombstoned' WHERE public_id = ?1",
        &[terminal_id(1).as_str()],
    );
    assert_eq!(
        refusal(&registry),
        format!("live terminal {} has lifecycle tombstoned", terminal_id(1))
    );
}

/// The host row of terminal `index`, marked closed.
fn close_host(registry: &WorkspaceRegistry, index: u64) {
    change_one_row(
        registry,
        "UPDATE terminal_hosts SET lifecycle = 'tombstoned' WHERE terminal_id = ?1",
        &[host_id(index).as_str()],
    );
}

#[test]
fn open_invariants_refuse_a_terminal_with_no_live_host() {
    let registry = registry_with_workspaces(2);
    close_host(&registry, 1);
    assert_eq!(
        refusal(&registry),
        format!("terminal resource {} has no live placement", terminal_id(1))
    );
}

/// Two bad rows of two rules: the checks name the pane, whose loop runs
/// before the loop of the terminals, also when the terminal's row comes
/// first in its table.
#[test]
fn open_invariants_name_the_rule_of_the_first_loop() {
    let registry = registry_with_workspaces(2);
    close_host(&registry, 0);
    change_one_row(
        &registry,
        "UPDATE resource_panes SET active_tab_id = NULL WHERE public_id = ?1",
        &[pane_id(1).as_str()],
    );
    assert_eq!(refusal(&registry), format!("pane {} has tabs but no active tab", pane_id(1)));
}

/// Two bad rows of one rule: the checks name the bad row that the query of
/// the rule gives first (here workspace 1, whose row was written before that
/// of workspace 2), not the one that was changed last. The query has no
/// ORDER BY: the test holds the order that SQLite gives for it today.
#[test]
fn open_invariants_name_the_first_bad_row_of_a_rule() {
    let registry = registry_with_workspaces(3);
    for index in [2, 1] {
        change_one_row(
            &registry,
            "UPDATE resource_workspaces SET active_screen_id = NULL WHERE public_id = ?1",
            &[workspace_id(index).as_str()],
        );
    }
    assert_eq!(
        refusal(&registry),
        format!("workspace {} has screens but no active screen", workspace_id(1))
    );
}
