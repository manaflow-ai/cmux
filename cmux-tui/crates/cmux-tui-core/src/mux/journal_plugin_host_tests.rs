//! The journal plugin (the agent screen detection) starts with the daemon's first terminal, not
//! at daemon start (CMUX-571, goal ram-baseline), and at once when a terminal is already there.

use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::SurfaceOptions;
use crate::mux::Mux;
use crate::terminal_backend::DEFAULT_WINDOW_BYTES;
use crate::terminal_backend::channel::ChannelTable;
use crate::terminal_backend::pty::BackendSide;
use crate::terminal_backend::terminals::TerminalMeta;
use crate::terminal_backend::{BackendId, LocalId};

/// A terminal in the catalog with no process: a byte-backend terminal whose app side drops input.
fn add_terminal(mux: &Arc<Mux>, channels: &Arc<ChannelTable<TerminalMeta>>, name: &str) {
    let meta = TerminalMeta {
        id: BackendId::app("cmux/test", &LocalId::new(name).unwrap()),
        target: "conn_1".into(),
        run_key: None,
    };
    let terminal = channels.insert("cmux/test", meta, DEFAULT_WINDOW_BYTES, true);
    let side = BackendSide { channels: channels.clone(), terminal, send: Arc::new(|_| {}) };
    mux.spawn_backend_terminal(side).unwrap();
}

fn until(what: &str, mut ok: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !ok() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_daemon_with_no_terminal_starts_the_plugin_with_its_first_terminal() {
    let mux = Mux::new_for_test("journal-plugin-gate-empty", SurfaceOptions::default());
    assert!(!mux.holds_a_terminal(), "the test daemon must start with no terminal");
    let socket = std::env::temp_dir().join("journal-plugin-gate-empty.sock");
    mux.start_journal_plugin(socket);
    std::thread::sleep(Duration::from_millis(200));
    assert!(!mux.journal_plugin.has_started(), "no terminal yet, so no plugin");

    let channels = Arc::new(ChannelTable::new("term"));
    add_terminal(&mux, &channels, "first");
    until("the plugin to start with the first terminal", || mux.journal_plugin.has_started());
    mux.shutdown();
}

#[test]
fn a_daemon_that_holds_a_terminal_starts_the_plugin_at_once() {
    let mux = Mux::new_for_test("journal-plugin-gate-restored", SurfaceOptions::default());
    let channels = Arc::new(ChannelTable::new("term"));
    add_terminal(&mux, &channels, "restored");
    let socket = std::env::temp_dir().join("journal-plugin-gate-restored.sock");
    mux.start_journal_plugin(socket);
    assert!(mux.journal_plugin.has_started(), "a terminal is there, so the plugin starts at once");
    mux.shutdown();
}
