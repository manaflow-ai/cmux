//! The screen detector's journal filter against a real headless owner and
//! against the request catalog.
//!
//! The detector (`bindings/examples/rust-agent-screen-detection`) is a Cargo
//! workspace of its own, so a test of this workspace cannot link it. Its list
//! of journal kinds is in a file with no dependency (`src/wake_kinds.rs`),
//! which this test compiles as a module: the list here is the detector's own
//! list, not a copy.
//!
//! The detector follows the journal with that list (`scanner.rs`,
//! `scan_connection`: from the tail, `follow`, sensitivity `sensitive`). An
//! owner that refuses the subscribe leaves the detector with no wake stream:
//! the detector scans nothing and connects again.

#![cfg(unix)]

mod fault_support;

#[path = "../../../bindings/examples/rust-agent-screen-detection/src/wake_kinds.rs"]
mod detector_wake_kinds;

use std::path::Path;
use std::time::Duration;

use cmux::{
    Client, Config, JournalSensitivity, JournalStart, Selector, SessionId, SessionJournalOptions,
};
use detector_wake_kinds::journal_wake_kinds;
use fault_support::{FaultDir, NO_MAINTENANCE, Owner};
use serde_json::{Value, json};

const READY_BOUND: Duration = Duration::from_secs(60);

/// The request catalog: the owner validates each request against it.
const CATALOG: &str = include_str!("../../../spec/resource-operations-v2.json");

/// The kinds that the request catalog permits in one journal filter.
fn catalog_bound_of_kinds() -> usize {
    let catalog: Value = serde_json::from_str(CATALOG).unwrap();
    let bound = &catalog["types"]["JournalFilter"]["fields"]["kinds"]["type"]["max_items"];
    usize::try_from(bound.as_u64().expect("`JournalFilter.kinds` has no `max_items`")).unwrap()
}

/// `count` kinds: the detector's list first, then names of no real kind.
fn kinds(count: usize) -> Vec<String> {
    journal_wake_kinds()
        .into_iter()
        .chain((0..).map(|index| format!("detector_test.kind_{index}")))
        .take(count)
        .collect()
}

/// Follows the journal of `session_name` as the detector does, with `kinds`
/// as the kinds of the filter, and calls `while_open` while the stream is
/// open. An owner that refuses the stream gives the text of its error.
fn follow_journal<T>(
    socket: &Path,
    session_name: &str,
    kinds: Vec<String>,
    while_open: impl FnOnce() -> T,
) -> Result<T, String> {
    let selector = match SessionId::parse(session_name.to_owned()) {
        Ok(id) => Selector::id(id),
        Err(_) => Selector::name(session_name.to_owned()),
    };
    let client =
        Client::connect(Config::from_socket_path(socket)).map_err(|error| error.to_string())?;
    let session = client.session(selector);
    let _stream = session
        .journal(SessionJournalOptions {
            start: Some(JournalStart::Tail),
            follow: Some(true),
            kinds,
            max_sensitivity: Some(JournalSensitivity::Sensitive),
            ..Default::default()
        })
        .map_err(|error| error.to_string())?;
    Ok(while_open())
}

/// The kinds of each live journal follower of the owner (`server-stats`,
/// section `journal_followers`), sorted as the owner gives them.
fn live_followers(owner: &Owner<'_>) -> Vec<Vec<String>> {
    let stats = owner.data(json!({"cmd": "server-stats", "include": ["journal_followers"]}));
    stats["journal_followers"]["followers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|row| row["left_ms"].is_null())
        .map(|row| {
            row["kinds"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|kind| kind.as_str().map(str::to_owned))
                .collect()
        })
        .collect()
}

/// The owner serves a journal stream with `sent` as the kinds of its filter,
/// and has a live follower row with these kinds while the stream is open.
fn assert_served_with_a_follower_row(label: &str, mut sent: Vec<String>) {
    let dir = FaultDir::new(label);
    let owner = Owner::start(&dir, label, &[NO_MAINTENANCE], READY_BOUND);
    let count = sent.len();
    let followers = follow_journal(&dir.socket(), label, sent.clone(), || live_followers(&owner))
        .unwrap_or_else(|error| {
            panic!("the owner refused a journal filter of {count} kinds: {error}")
        });
    sent.sort();
    assert!(
        followers.contains(&sent),
        "no live follower row has the {count} kinds of the filter: {followers:#?}"
    );
    owner.stop();
}

#[test]
fn detector_journal_filter_is_served_and_has_a_follower_row() {
    assert_served_with_a_follower_row("djf-own", journal_wake_kinds());
}

/// The guard: a list that the catalog does not permit is refused by each
/// owner, and the detector then follows nothing.
#[test]
fn detector_journal_filter_fits_the_bound_of_the_request_catalog() {
    let count = journal_wake_kinds().len();
    let bound = catalog_bound_of_kinds();
    assert!(
        count <= bound,
        "the detector's journal filter has {count} kinds; the request catalog permits {bound} \
         kinds in one filter (`JournalFilter.kinds`, spec/resource-operations-v2.json)"
    );
}

/// Control: the owner serves a filter with as many kinds as the catalog
/// permits, so the owner has no smaller bound of its own.
#[test]
fn detector_journal_filter_control_a_filter_at_the_catalog_bound_is_served() {
    assert_served_with_a_follower_row("djf-bound", kinds(catalog_bound_of_kinds()));
}

/// Control: one kind above the catalog's bound is refused, with the text
/// that the detector then prints, and leaves no follower row.
#[test]
fn detector_journal_filter_control_one_kind_above_the_catalog_bound_is_refused() {
    let dir = FaultDir::new("djf-above");
    let session = "djf-above";
    let owner = Owner::start(&dir, session, &[NO_MAINTENANCE], READY_BOUND);
    let count = catalog_bound_of_kinds() + 1;
    let refused = follow_journal(&dir.socket(), session, kinds(count), || ())
        .expect_err("the owner served a journal filter with one kind above the catalog's bound");
    assert!(refused.contains("value has too many items"), "{refused}");
    let followers = live_followers(&owner);
    assert!(followers.is_empty(), "a refused stream left a follower row: {followers:#?}");
    owner.stop();
}
