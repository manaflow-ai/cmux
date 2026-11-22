//! Terminal tail pins end to end in one mux: a pin publishes the terminal's
//! last line as its workspace's `tail:` status entry, at most once per
//! interval; unpinning, or the terminal ending, removes it and stops the
//! publisher; an unpinned terminal queues nothing.

use std::time::Duration;

use serde_json::Value;

use super::*;
use crate::SurfaceOptions;
use crate::terminal_tail::PUBLISH_INTERVAL;

fn wait_for(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::sleep(Duration::from_millis(2));
    }
}

struct Fixture {
    mux: Arc<Mux>,
    surface: Arc<Surface>,
    workspace: String,
}

fn fixture(name: &str) -> Fixture {
    let mux = Mux::new_for_test(name, SurfaceOptions::default());
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let workspace = mux.workspace_public_id_of_surface(surface.id).expect("the tab's workspace");
    Fixture { mux, surface, workspace }
}

impl Fixture {
    /// The `tail:` entries of the workspace, as `(key, text)`.
    fn tails(&self) -> Vec<(String, String)> {
        let selectors = self.mux.local_workspace_selectors(&self.workspace);
        let snapshots = self.mux.workspace_status_snapshots(&selectors).unwrap();
        snapshots[0]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| {
                entry["key"].as_str().is_some_and(|key| key.starts_with(TAIL_KEY_PREFIX))
            })
            .map(|entry| {
                (
                    entry["key"].as_str().unwrap().to_owned(),
                    entry["text"].as_str().unwrap().to_owned(),
                )
            })
            .collect()
    }

    fn tail_text(&self) -> Option<String> {
        self.tails().into_iter().next().map(|(_, text)| text)
    }

    fn print(&self, bytes: &[u8]) {
        self.surface.apply_stream_output_for_test(bytes).unwrap();
    }

    fn revision(&self) -> u64 {
        self.mux.with_state(|state| state.resource_revision)
    }
}

#[test]
fn a_pinned_terminal_shows_its_last_line_without_escapes_under_its_workspace() {
    let f = fixture("tail-pin-shows");
    f.print(b"\x1b[1;32mbuilding\x1b[0m step 1\r\n");
    let terminal = f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    assert!(f.mux.terminal_tail_pinned(f.surface.id));
    // The pin publishes the screen's last line at once.
    wait_for("the seeded tail published", || f.tail_text().as_deref() == Some("building step 1"));
    assert_eq!(f.tails()[0].0, format!("{TAIL_KEY_PREFIX}{}", terminal.as_str()));

    f.print(b"\x1b[33mwarning\x1b[0m: \x1b]8;;https://x\x07unused\x1b]8;;\x07 import\r\n\r\n");
    wait_for("the new line published", || {
        f.tail_text().as_deref() == Some("warning: unused import")
    });
    let selectors = f.mux.local_workspace_selectors(&f.workspace);
    let entry = &f.mux.workspace_status_snapshots(&selectors).unwrap()[0]["entries"][0];
    assert_eq!(entry["icon"], "terminal");
    assert_eq!(entry["owner"]["terminal"], Value::String(terminal.as_str().to_owned()), "{entry}");
}

#[test]
fn a_burst_of_lines_publishes_at_most_once_per_interval_and_ends_on_the_newest() {
    let f = fixture("tail-pin-throttle");
    f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    f.print(b"line 0\n");
    wait_for("the first line published", || f.tail_text().as_deref() == Some("line 0"));
    let before = f.revision();
    let started = Instant::now();
    for index in 1..=200 {
        f.print(format!("line {index}\n").as_bytes());
    }
    wait_for("the newest line published", || f.tail_text().as_deref() == Some("line 200"));
    let elapsed = started.elapsed();
    let commits = f.revision() - before;
    // One commit per interval that passed, plus the trailing one.
    let allowed = 1 + (elapsed.as_millis() / PUBLISH_INTERVAL.as_millis()) as u64 + 1;
    assert!(commits <= allowed, "{commits} commits in {elapsed:?} (at most {allowed})");
    assert!(commits < 10, "200 lines made {commits} commits");
}

#[test]
fn unpinning_removes_the_line_and_stops_the_publisher() {
    let f = fixture("tail-pin-unpin");
    f.print(b"deploying\n");
    f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    wait_for("the tail published", || f.tail_text().is_some());
    f.mux.set_terminal_tail_pin(f.surface.id, false).unwrap();
    assert!(!f.mux.terminal_tail_pinned(f.surface.id));
    assert_eq!(f.tails(), Vec::new(), "unpinning left the line");
    wait_for("the publisher thread ended", || !f.mux.terminal_tail_pins.worker_running());

    // Output after the unpin changes nothing.
    let before = f.revision();
    f.print(b"more output\n");
    std::thread::sleep(PUBLISH_INTERVAL * 2);
    assert_eq!(f.tails(), Vec::new());
    assert_eq!(f.revision(), before, "an unpinned terminal committed");
}

#[test]
fn an_unpinned_terminal_queues_nothing_and_starts_no_thread() {
    let f = fixture("tail-pin-idle");
    for _ in 0..50 {
        f.print(b"busy output\r\n");
    }
    assert!(!f.mux.terminal_tail_pins.worker_running());
    assert!(f.mux.terminal_tail_pins.lock().due.is_empty());
    assert_eq!(f.tails(), Vec::new());
}

#[test]
fn an_ended_terminal_drops_its_pin_and_its_line() {
    let f = fixture("tail-pin-exit");
    f.print(b"tail -f app.log\n");
    f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    wait_for("the tail published", || f.tail_text().is_some());
    // What the reader and the exit run when a terminal's output ends.
    f.mux.settle_terminal_publications(&f.surface);
    assert!(!f.mux.terminal_tail_pinned(f.surface.id));
    assert_eq!(f.tails(), Vec::new(), "an ended terminal kept its line");
    wait_for("the publisher thread ended", || !f.mux.terminal_tail_pins.worker_running());
}

#[test]
fn closing_a_quiet_pinned_tab_ends_its_pin_and_its_line() {
    let f = fixture("tail-pin-close-tab");
    let pane = f.mux.with_state(|state| state.pane_of(f.surface.id)).expect("the tab's pane");
    // A second tab keeps the workspace open.
    let _other = f.mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    f.print(b"watching\n");
    let terminal = f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    wait_for("the tail published", || f.tail_text().is_some());
    // No output after the close: the publisher's quiet pass finds no tab.
    f.mux.close_surface(f.surface.id).unwrap();
    wait_for("the line went away", || f.tails().is_empty());
    wait_for("the publisher thread ended", || !f.mux.terminal_tail_pins.worker_running());
    // An unpin by terminal id with no tab answers, and there is nothing to end.
    assert!(!f.mux.end_terminal_tail_of(terminal.as_str()));
}

#[test]
fn unpinning_by_terminal_id_ends_the_pin_from_its_record() {
    let f = fixture("tail-pin-by-id");
    f.print(b"deploying\n");
    let terminal = f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    wait_for("the tail published", || f.tail_text().is_some());
    assert!(f.mux.end_terminal_tail_of(terminal.as_str()));
    assert!(!f.mux.terminal_tail_pinned(f.surface.id));
    assert_eq!(f.tails(), Vec::new());
}

#[test]
fn a_restart_keeps_a_status_key_that_only_looks_like_a_tail() {
    let f = fixture("tail-pin-foreign");
    // A script's own entry under a `tail:` key, not made by a pin.
    let selectors = f.mux.local_workspace_selectors(&f.workspace);
    f.mux
        .state_workspace_status(
            &WorkspaceMutation::daemon_local("test"),
            "workspace_status.set",
            None,
            &selectors,
            WorkspaceStatusChange::Set {
                key: "tail:deploy".into(),
                text: "watching".into(),
                icon: None,
                color: None,
                meta: Box::default(),
            },
        )
        .unwrap();
    f.mux.clear_stale_terminal_tails();
    assert_eq!(f.tails(), vec![("tail:deploy".to_owned(), "watching".to_owned())]);
}

#[test]
fn only_the_daemon_sets_a_reserved_tail_key() {
    let f = fixture("tail-pin-reserved");
    let terminal = f.surface.terminal_public_id().cloned().unwrap();
    let selectors = f.mux.local_workspace_selectors(&f.workspace);
    let refused = f
        .mux
        .state_workspace_status(
            &WorkspaceMutation::by_local_user("forge-1", "test").unwrap(),
            "workspace_status.set",
            None,
            &selectors,
            WorkspaceStatusChange::Set {
                key: format!("{RESERVED_TAIL_KEY_PREFIX}{}", &terminal.as_str()[5..]),
                text: "forged".into(),
                icon: Some("terminal".into()),
                color: None,
                meta: Box::default(),
            },
        )
        .unwrap_err();
    assert!(refused.to_string().contains("reserved"), "{refused}");
    assert_eq!(f.tails(), Vec::new());
}

#[test]
fn an_unpin_during_a_publication_is_never_undone() {
    let f = fixture("tail-pin-race");
    f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    for round in 0..20 {
        f.print(format!("round {round}\n").as_bytes());
        // Unpin while the publisher may be committing this line.
        f.mux.set_terminal_tail_pin(f.surface.id, false).unwrap();
        std::thread::sleep(PUBLISH_INTERVAL / 10);
        assert_eq!(f.tails(), Vec::new(), "round {round}: a publication outlived the unpin");
        f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    }
    // A publication that took its line holds the lock, so the unpin waits for it.
    let guard = f.mux.terminal_tail_pins.publishing();
    let unpin = {
        let mux = f.mux.clone();
        let id = f.surface.id;
        std::thread::spawn(move || mux.set_terminal_tail_pin(id, false).unwrap())
    };
    std::thread::sleep(Duration::from_millis(50));
    assert!(!unpin.is_finished(), "an unpin did not wait for the publication in flight");
    drop(guard);
    unpin.join().unwrap();
    assert_eq!(f.tails(), Vec::new());
}

#[test]
fn an_incognito_terminal_is_never_pinned_and_a_pin_ends_when_it_turns_private() {
    let f = fixture("tail-pin-private");
    let terminal = f.surface.terminal_public_id().cloned().unwrap();
    f.print(b"secret output\n");
    f.mux.output_store.mark_private(&terminal);
    let refused = f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap_err();
    assert!(refused.to_string().contains("terminal_private"), "{refused}");
    assert!(!f.mux.terminal_tail_pinned(f.surface.id));
    std::thread::sleep(PUBLISH_INTERVAL);
    assert_eq!(f.tails(), Vec::new(), "a private terminal's line reached the status store");

    // A pin made while public ends, without publishing, once the terminal turns private.
    let g = fixture("tail-pin-turns-private");
    let terminal = g.surface.terminal_public_id().cloned().unwrap();
    g.print(b"public line\n");
    g.mux.set_terminal_tail_pin(g.surface.id, true).unwrap();
    wait_for("the public tail published", || g.tail_text().is_some());
    g.mux.output_store.mark_private(&terminal);
    g.print(b"private line\n");
    wait_for("the pin ended", || !g.mux.terminal_tail_pinned(g.surface.id));
    assert_eq!(g.tails(), Vec::new());
}

#[test]
fn concurrent_pins_and_unpins_always_leave_a_working_pin() {
    let f = fixture("tail-pin-concurrent");
    let togglers: Vec<_> = (0..4)
        .map(|index| {
            let mux = f.mux.clone();
            let id = f.surface.id;
            std::thread::spawn(move || {
                for round in 0..50 {
                    mux.set_terminal_tail_pin(id, (round + index) % 2 == 0).unwrap();
                }
            })
        })
        .collect();
    for toggler in togglers {
        toggler.join().unwrap();
    }
    f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    f.print(b"after the storm\n");
    wait_for("a pin after concurrent toggles published", || {
        f.tail_text().as_deref() == Some("after the storm")
    });
    f.mux.set_terminal_tail_pin(f.surface.id, false).unwrap();
    assert_eq!(f.tails(), Vec::new());
    assert!(f.mux.terminal_tail_pins.lock().pins.is_empty());
}

#[test]
fn a_restart_clears_the_lines_an_earlier_run_left() {
    let f = fixture("tail-pin-stale");
    f.print(b"left over\n");
    f.mux.set_terminal_tail_pin(f.surface.id, true).unwrap();
    wait_for("the tail published", || f.tail_text().is_some());
    // A new daemon has no pins; the entry is all that is left.
    f.mux.terminal_tail_pins.lock().pins.clear();
    f.mux.clear_stale_terminal_tails();
    assert_eq!(f.tails(), Vec::new());
}
