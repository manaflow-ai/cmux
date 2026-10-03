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
        "git.diff",
        "git.files.search",
        "stream.cancel",
    ] {
        let operation: ResourceOperation =
            serde_json::from_str(&format!("\"{name}\"")).expect("known operation");
        assert_eq!(operation.wire_name(), name);
        assert_eq!(serde_json::to_string(&operation).unwrap(), format!("\"{name}\""));
    }
}
