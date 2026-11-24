//! The `cmux-lifeline` typestate handles (`Vm<S, T>`) sit over this table: every edge a handle
//! has must be a transition [`step`] makes. The handles give the compile-time order; the table
//! is the runtime truth the other languages replay. An edge the handles allow and the table
//! refuses, or lands elsewhere, fails here.

use cmux_lifeline::vm::{EDGES, Edge};

use super::*;

/// The table state a handle state stands for. `Attached` is `ready` with an open attach (the
/// table does not model the attach session); `Deleted` is `destroyed`.
fn table_state(handle: &str) -> Option<&'static str> {
    Some(match handle {
        "Provisioning" => "provisioning",
        "Running" => "running",
        "Ready" | "Attached" => "ready",
        "Pausing" => "pausing",
        "Paused" => "paused",
        "Starting" => "starting",
        "Deleting" => "deleting",
        "Deleted" => "destroyed",
        "Failed" => "failed",
        "Unknown" => "unknown",
        // Not power states the table holds: a transport before identification, and a stopped
        // VM (the table reads `stopped` as paused: [`Observation::from_status`]).
        "Unidentified" | "Stopped" => return None,
        other => panic!("cmux-lifeline state {other} has no decision here: add it"),
    })
}

/// The table events that can stand for a handle method.
fn events_for(method: &str) -> &'static [&'static str] {
    match method {
        "running" => &["succeeded", "failed", "observed_running"],
        "ready" => &["daemon_ready"],
        "attach" => &["attach"],
        "pause" => &["pause"],
        "paused" => &["succeeded", "failed", "observed_paused"],
        "resume" => &["resume"],
        "deleted" => &["succeeded", "observed_destroyed"],
        "delete" => &["delete"],
        "failed" => &["failed", "observed_failed"],
        "uncertain" => &["timed_out", "observed_unknown"],
        // Local to the client: closing an attach changes no power state.
        "detach" => &[],
        // Only between handle states the table does not hold (`Stopped`).
        "stopped" | "start" => &[],
        other => panic!("cmux-lifeline method {other} has no decision here: add it"),
    }
}

/// What the table does for `edge`: Ok when one of its events moves `from` to `to`.
fn check(edge: &Edge) -> Result<(), String> {
    let (Some(from), Some(to)) = (table_state(edge.from), table_state(edge.to)) else {
        return Ok(());
    };
    let events = events_for(edge.method);
    if events.is_empty() {
        return if from == to { Ok(()) } else { Err(format!("{edge:?}: no table event")) };
    }
    let machine = sample_states()
        .into_iter()
        .find(|m| m.power.kind() == from)
        .expect("a sample per table state");
    let mut seen = Vec::new();
    for event in sample_events(machine.issued) {
        if !events.contains(&event.kind()) {
            continue;
        }
        match step(machine, event) {
            Ok((after, _)) if after.power.kind() == to => return Ok(()),
            Ok((after, _)) => seen.push(format!("{} -> {}", event.kind(), after.power.kind())),
            Err(refusal) => seen.push(format!("{} refused {refusal}", event.kind())),
        }
    }
    Err(format!("{edge:?}: the table says {}", seen.join(", ")))
}

/// Edges the handles allow and the table does not, each with why. This list only shrinks: a new
/// disagreement fails [`every_lifeline_edge_is_a_table_transition`], and an entry that starts
/// agreeing fails [`known_divergences_still_diverge`] until it is removed. Each is a decision for
/// whoever changes either side (RFD 0026: the table is the runtime truth).
const KNOWN_DIVERGENCES: &[(&str, &str, &str)] = &[
    // Reverts after a refused operation. The table does not trust a failure to say where it
    // left the VM: `failed` moves to `unknown`, and a refresh's observation moves on from there.
    (
        "Pausing",
        "running",
        "two steps in the table: failed -> unknown, observed_running -> running",
    ),
    ("Starting", "paused", "two steps in the table: failed -> failed or unknown, then observed"),
    // A second power call while one is in flight. The table refuses it (RFD 0026: "two power
    // calls in flight" is unrepresentable). The handles' `Provisioning` is a create the provider
    // accepted (cmux-vm run.rs deletes it on cleanup); the table's is a create not yet answered.
    ("Provisioning", "delete", "table: operation_in_flight; the two Provisioning states differ"),
    ("Pausing", "delete", "table: operation_in_flight"),
    ("Starting", "delete", "table: operation_in_flight"),
    // A provider failure noticed with no answer pending. The table takes observations only as
    // answers to its own refresh; it has no unsolicited observation or refresh intent yet.
    ("Running", "failed", "table: not_awaited (no refresh intent)"),
    ("Ready", "failed", "table: not_awaited (no refresh intent)"),
    ("Attached", "failed", "table: not_awaited (no refresh intent)"),
    ("Pausing", "failed", "table: the pause failing is not the VM failing; it moves to unknown"),
    ("Deleting", "failed", "table: the delete failing moves to unknown"),
    ("Ready", "uncertain", "table: not_awaited (nothing in flight to time out)"),
    ("Attached", "uncertain", "table: not_awaited (nothing in flight to time out)"),
    ("Paused", "uncertain", "table: not_awaited (nothing in flight to time out)"),
    ("Failed", "uncertain", "table: not_awaited (nothing in flight to time out)"),
];

fn known(edge: &Edge) -> bool {
    KNOWN_DIVERGENCES.iter().any(|(from, method, _)| *from == edge.from && *method == edge.method)
}

#[test]
fn every_lifeline_edge_is_a_table_transition() {
    let disagreements: Vec<String> =
        EDGES.iter().filter(|e| !known(e)).filter_map(|e| check(e).err()).collect();
    assert!(
        disagreements.is_empty(),
        "lifeline and power table disagree (fix one side, or name it in KNOWN_DIVERGENCES):\n{}",
        disagreements.join("\n")
    );
}

#[test]
fn known_divergences_still_diverge() {
    for (from, method, why) in KNOWN_DIVERGENCES {
        let edge = EDGES
            .iter()
            .find(|e| e.from == *from && e.method == *method)
            .unwrap_or_else(|| panic!("{from}.{method} is no lifeline edge: remove it"));
        assert!(
            check(edge).is_err(),
            "{from}.{method} now agrees ({why}): remove it from the list"
        );
    }
}

#[test]
fn the_edges_off_the_table_are_the_named_ones() {
    let off: Vec<String> = EDGES
        .iter()
        .filter(|e| table_state(e.from).is_none() || table_state(e.to).is_none())
        .map(|e| format!("{}.{}", e.from, e.method))
        .collect();
    assert_eq!(
        off,
        [
            "Unidentified.ready",
            "Starting.stopped",
            "Stopped.start",
            "Stopped.delete",
            "Stopped.uncertain"
        ]
    );
}
