//! Projection convergence for pane splits (OWNERSHIP-PRINCIPLES invariant 4):
//! the screen value that `session.events` publishes for a revision equals the
//! screen value `session.snapshot` returns at that revision.

use super::*;

/// The `session.snapshot` revision and its screens by id.
fn snapshot_screens(mux: &Arc<Mux>) -> (u64, HashMap<String, Value>) {
    let snapshot = public_session_snapshot(mux).unwrap();
    let revision = snapshot["cursor"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
    let screens = snapshot["screens"]
        .as_array()
        .unwrap()
        .iter()
        .map(|screen| (screen["id"].as_str().unwrap().to_string(), screen.clone()))
        .collect();
    (revision, screens)
}

/// Every screen upsert committed after `after`, as (revision, screen id, value).
fn screen_upserts_after(mux: &Arc<Mux>, after: u64) -> Vec<(u64, String, Value)> {
    mux.resource_events_after(after)
        .unwrap()
        .batches
        .into_iter()
        .flat_map(|batch| {
            let revision = batch.revision;
            batch
                .changes
                .as_array()
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|change| change["kind"] == "upsert" && change["resource"] == "screen")
                .map(move |change| {
                    (revision, change["id"].as_str().unwrap().to_string(), change["value"].clone())
                })
        })
        .collect()
}

/// Asserts that the events since `after` converge to the snapshot: each screen
/// upsert at the snapshot revision equals the snapshot's screen, and the last
/// upsert of every screen equals it too. Returns the snapshot revision.
fn assert_screen_events_match_snapshot(mux: &Arc<Mux>, after: u64, step: &str) -> u64 {
    let (revision, screens) = snapshot_screens(mux);
    let upserts = screen_upserts_after(mux, after);
    assert!(!upserts.is_empty(), "{step}: no screen upsert was published after {after}");
    let mut last = HashMap::new();
    for (event_revision, id, value) in upserts {
        assert!(event_revision <= revision, "{step}: event revision passed the snapshot");
        let snapshot_value = screens
            .get(&id)
            .unwrap_or_else(|| panic!("{step}: event screen {id} is not in the snapshot"));
        if event_revision == revision {
            assert_eq!(
                &value, snapshot_value,
                "{step}: session.events screen {id} at revision {revision} differs from session.snapshot"
            );
        }
        last.insert(id, value);
    }
    for (id, value) in last {
        assert_eq!(
            &value, &screens[&id],
            "{step}: the last session.events upsert of screen {id} differs from session.snapshot"
        );
    }
    revision
}

fn split(mux: &Arc<Mux>, pane: &str, fields: Value, key: &str) -> Value {
    dispatch(
        mux,
        parsed(
            ResourceOperation::PaneSplit,
            selectors(None, None, Some(pane), None),
            fields,
            Some(key),
        ),
    )
    .unwrap()
}

#[test]
fn viewport_split_screen_events_equal_snapshot_screens() {
    let mux = mux();
    let start = snapshot_screens(&mux).0;
    let created = terminal_workspace(&mux, "split-events");
    let first_pane = created["value"]["pane_id"].as_str().unwrap().to_string();
    let revision = assert_screen_events_match_snapshot(&mux, start, "workspace.create");

    let viewport = split(
        &mux,
        &first_pane,
        json!({"direction":"right","viewport_width":0.5}),
        "split-events-viewport",
    );
    let (_, screens) = snapshot_screens(&mux);
    let screen = viewport["value"]["screen_id"].as_str().unwrap();
    assert_eq!(screens[screen]["layout"]["root"]["kind"], "viewport");
    let revision = assert_screen_events_match_snapshot(&mux, revision, "pane.split viewport");

    let second_pane = viewport["value"]["pane_id"].as_str().unwrap().to_string();
    split(
        &mux,
        &second_pane,
        json!({"direction":"right","viewport_width":0.5}),
        "split-events-viewport-again",
    );
    let revision = assert_screen_events_match_snapshot(&mux, revision, "pane.split viewport again");

    split(&mux, &first_pane, json!({"direction":"down"}), "split-events-down-in-column");
    assert_screen_events_match_snapshot(&mux, revision, "pane.split down in column");
}
