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
        let selectors = crate::ResourceSelectors {
            workspace: Some(self.workspace.clone()),
            ..Default::default()
        };
        let snapshots = self.mux.workspace_status_snapshots(&selectors).unwrap();
        snapshots[0]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| entry["key"].as_str().is_some_and(|key| key.starts_with(TAIL_KEY_PREFIX)))
            .map(|entry| {
                (entry["key"].as_str().unwrap().to_owned(), entry["text"].as_str().unwrap().to_owned())
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
    wait_for("the new line published", || f.tail_text().as_deref() == Some("warning: unused import"));
    let selectors =
        crate::ResourceSelectors { workspace: Some(f.workspace.clone()), ..Default::default() };
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
