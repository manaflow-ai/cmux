//! The per-terminal relaunch record (`terminal_relaunch`): Reopen Closed
//! starts a terminal tab in the directory it last reported, with the
//! allowlisted environment, and no secret value ever reaches SQLite.

use serde_json::json;

use super::tests::{mutate, read, tab_id, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

const SECRET: &str = "relaunch-secret-value-5c1f";

/// The surface that shows the public tab `tab`.
fn surface_of_tab(mux: &Arc<Mux>, tab: &str) -> Arc<crate::Surface> {
    let id = mux
        .with_state(|state| {
            state
                .resource_indexes
                .tab_ids
                .iter()
                .find(|(_, public)| public.to_string() == tab)
                .map(|(surface, _)| *surface)
        })
        .unwrap_or_else(|| panic!("no surface shows tab {tab}"));
    mux.surface(id).expect("reopened surface")
}

/// Close `surface`'s tab, end its terminal (the test runtime's placeholder
/// never exits, so reopen would otherwise reattach the same terminal), then
/// reopen the newest closed group, which starts a new terminal.
fn close_and_reopen(mux: &Arc<Mux>, surface: SurfaceId, key: &str) -> Arc<crate::Surface> {
    let tab = tab_id(mux, surface);
    let terminal = mux
        .surface(surface)
        .and_then(|surface| surface.terminal_public_id().cloned())
        .expect("a hosted terminal tab");
    mutate(mux, "tab.close", json!({"tab": tab}), &format!("{key}-close"));
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 1,
    };
    mux.persist_terminal_exit_for_test(&terminal, &exit).expect("the closed terminal ends");
    let closed = read(mux, "closed.list", json!({}));
    let reopened =
        mutate(mux, "closed.reopen", json!({"closed": closed[0]["id"]}), &format!("{key}-reopen"));
    surface_of_tab(mux, reopened["tab_ids"][0].as_str().expect("reopened tab id"))
}

/// Every text value of every table in the registry database.
fn registry_text(mux: &Arc<Mux>) -> Vec<(String, String)> {
    mux.read_registry_state(|connection| {
        let mut tables =
            connection.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")?;
        let names =
            tables.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?;
        let mut out = Vec::new();
        for name in names {
            let mut rows = connection.prepare(&format!("SELECT * FROM \"{name}\""))?;
            let columns = rows.column_count();
            let mut cursor = rows.query([])?;
            while let Some(row) = cursor.next()? {
                for index in 0..columns {
                    if let rusqlite::types::ValueRef::Text(text) = row.get_ref(index)? {
                        out.push((name.clone(), String::from_utf8_lossy(text).into_owned()));
                    }
                }
            }
        }
        Ok(out)
    })
    .unwrap()
}

/// The finding behind "~" on reopened tabs: the closed record kept no cwd,
/// so the reopened shell started in $HOME.
#[test]
fn a_reopened_terminal_tab_starts_in_its_launch_directory() {
    let mux = Mux::new_for_test("relaunch-launch-cwd", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 1);
    let pane = mux.with_state(|state| state.pane_of(tabs[0])).unwrap();
    let launched = mux.new_tab(Some(pane), Some("/tmp".into()), None).unwrap();
    let reopened = close_and_reopen(&mux, launched.id, "launch");
    assert_eq!(reopened.spawn_cwd().as_deref(), Some("/tmp"));
    mux.shutdown();
}

/// A `cd` the shell reported with OSC 7 is the directory reopen uses.
#[test]
fn a_reopened_terminal_tab_starts_in_its_last_reported_directory() {
    let mux = Mux::new_for_test("relaunch-osc7-cwd", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 1);
    let pane = mux.with_state(|state| state.pane_of(tabs[0])).unwrap();
    let launched = mux.new_tab(Some(pane), Some("/tmp".into()), None).unwrap();
    launched.set_test_pwd(Some("file://localhost/usr".into()));
    launched.publish_pending_directory();
    let reopened = close_and_reopen(&mux, launched.id, "osc7");
    assert_eq!(reopened.spawn_cwd().as_deref(), Some("/usr"));
    mux.shutdown();
}

/// A reported directory that no longer exists is not used: reopen falls back
/// to the default directory instead of failing to start.
#[test]
fn a_reopened_terminal_tab_ignores_a_reported_directory_that_is_gone() {
    let mux = Mux::new_for_test("relaunch-gone-cwd", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 1);
    let pane = mux.with_state(|state| state.pane_of(tabs[0])).unwrap();
    let launched =
        mux.new_tab(Some(pane), Some("/nonexistent/relaunch-gone".into()), None).unwrap();
    let reopened = close_and_reopen(&mux, launched.id, "gone");
    assert_eq!(reopened.spawn_cwd(), None);
    mux.shutdown();
}

/// The allowlisted environment survives close and reopen; a value whose key
/// names a secret (TOKEN, KEY, SECRET, PASSWORD, AUTH, COOKIE, CREDENTIAL, in
/// any case) and every key outside the allowlist never reach SQLite.
#[test]
fn relaunch_env_keeps_allowlisted_keys_and_no_secret_reaches_sqlite() {
    let mux = Mux::new_for_test("relaunch-env", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 1);
    let pane = mux.with_state(|state| state.pane_of(tabs[0])).unwrap();
    let env = vec![
        ("CMUX_SOCKET_PATH".to_string(), "/tmp/relaunch-app.sock".to_string()),
        ("COLORTERM".to_string(), "truecolor".to_string()),
        ("CMUX_API_TOKEN".to_string(), SECRET.to_string()),
        ("CMUX_STACK_PASSWORD".to_string(), SECRET.to_string()),
        ("CMUX_SESSION_COOKIE".to_string(), SECRET.to_string()),
        ("MY_PRIVATE_THING".to_string(), SECRET.to_string()),
    ];
    let launched = mux.new_tab_with_env(Some(pane), Some("/tmp".into()), env, None).unwrap();
    let reopened = close_and_reopen(&mux, launched.id, "env");
    assert_eq!(reopened.spawn_cwd().as_deref(), Some("/tmp"));

    let text = registry_text(&mux);
    // Every table, the exactly-once receipts included (cx-1a6).
    let leaked = text.iter().filter(|(_, value)| value.contains(SECRET)).collect::<Vec<_>>();
    assert!(leaked.is_empty(), "a secret value reached SQLite: {leaked:?}");
    let relaunch = text
        .iter()
        .filter(|(table, _)| table == "terminal_relaunch")
        .map(|(_, value)| value.as_str())
        .collect::<Vec<_>>();
    assert!(
        relaunch.iter().any(|value| value.contains("/tmp/relaunch-app.sock")),
        "the allowlisted CMUX_SOCKET_PATH was not recorded: {relaunch:?}"
    );
    mux.shutdown();
}
