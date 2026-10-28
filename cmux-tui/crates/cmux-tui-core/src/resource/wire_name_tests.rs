//! Wire names of resource operations round-trip through serde.

use super::ResourceOperation;

#[test]
fn wire_name_round_trips_through_serde() {
    for name in [
        "machine.list",
        "session.journal.append",
        "workspace.create",
        "terminal.output_read",
        "browser.close",
        "git.branches",
        "git.diff",
        "git.files.list",
        "git.files.search",
        "stream.cancel",
        "origin.confirmation.issue",
    ] {
        let operation: ResourceOperation =
            serde_json::from_str(&format!("\"{name}\"")).expect("known operation");
        assert_eq!(operation.wire_name(), name);
        assert_eq!(serde_json::to_string(&operation).unwrap(), format!("\"{name}\""));
    }
}

/// `ALL` lists every operation serde knows, once (the request watchdog
/// names an operation from it).
#[test]
fn all_lists_every_operation_once() {
    let error = serde_json::from_str::<ResourceOperation>("\"no.such.operation\"")
        .expect_err("an unknown operation is refused")
        .to_string();
    let (_, expected) = error.split_once("expected one of ").expect("serde lists its variants");
    let expected = expected.split_once(" at line").map_or(expected, |(names, _)| names);
    let serde: std::collections::BTreeSet<&str> =
        expected.split(", ").map(|name| name.trim_matches('`')).collect();
    let listed: std::collections::BTreeSet<&str> =
        ResourceOperation::ALL.iter().map(|operation| operation.wire_name()).collect();
    assert_eq!(listed.len(), ResourceOperation::ALL.len(), "an operation is listed twice");
    let unlisted: Vec<_> = serde.difference(&listed).collect();
    let unknown: Vec<_> = listed.difference(&serde).collect();
    assert!(
        unlisted.is_empty() && unknown.is_empty(),
        "unlisted {unlisted:?}, unknown {unknown:?}"
    );
}
