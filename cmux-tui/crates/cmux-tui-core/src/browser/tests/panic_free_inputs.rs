//! Inputs the panic-free url_input and worker code (p10-stability-127) must
//! keep handling as before: odd typed URLs and mouse-move coalescing.

use super::{BrowserCommand, SequencedBrowserCommand, normalize_url};
use crate::browser::BrowserPointerOwner;
use crate::browser::worker::coalesce_worker_mouse_moves;

fn mouse(
    sequence: u64,
    input_owner: BrowserPointerOwner,
    event_type: &str,
) -> SequencedBrowserCommand {
    SequencedBrowserCommand {
        sequence,
        command: BrowserCommand::Mouse {
            input_owner,
            event_type: event_type.to_string(),
            x: 0.0,
            y: 0.0,
            button: None,
            click_count: None,
            frame_seq: None,
            pointer_admission: None,
        },
    }
}

fn sequences(batch: &[SequencedBrowserCommand]) -> Vec<u64> {
    batch.iter().map(|command| command.sequence).collect()
}

#[test]
fn coalescing_keeps_the_last_move_of_each_run_of_one_owner() {
    let local = BrowserPointerOwner::Local;
    let client = BrowserPointerOwner::Client(7);
    let mut batch = vec![
        mouse(1, local, "mouseMoved"),
        mouse(2, local, "mouseMoved"),
        mouse(3, local, "mouseMoved"),
        mouse(4, client, "mouseMoved"),
        mouse(5, local, "mousePressed"),
        mouse(6, local, "mouseMoved"),
        mouse(7, local, "mouseMoved"),
    ];
    coalesce_worker_mouse_moves(&mut batch);
    assert_eq!(sequences(&batch), vec![3, 4, 5, 7]);
}

#[test]
fn coalescing_an_empty_or_single_batch_changes_nothing() {
    let mut empty = Vec::new();
    coalesce_worker_mouse_moves(&mut empty);
    assert!(empty.is_empty());
    let mut one = vec![mouse(1, BrowserPointerOwner::Legacy, "mouseMoved")];
    coalesce_worker_mouse_moves(&mut one);
    assert_eq!(sequences(&one), vec![1]);
}

#[test]
fn odd_typed_urls_normalize_without_a_panic() {
    assert_eq!(normalize_url(""), "https://www.google.com/search?q=");
    assert_eq!(normalize_url("localhost"), "http://localhost");
    assert_eq!(normalize_url("localhostfoo"), "https://www.google.com/search?q=localhostfoo");
    assert_eq!(normalize_url("é"), "https://www.google.com/search?q=%C3%A9");
    assert_eq!(normalize_url("?q"), "https://www.google.com/search?q=%3Fq");
    assert_eq!(normalize_url("10.1.2.3"), "http://10.1.2.3");
    assert_eq!(normalize_url("8.8.8.8"), "https://8.8.8.8");
    assert_eq!(normalize_url("ü.local/x"), "http://ü.local/x");
    assert_eq!(normalize_url("[fd00::1]:80/"), "http://[fd00::1]:80/");
}
