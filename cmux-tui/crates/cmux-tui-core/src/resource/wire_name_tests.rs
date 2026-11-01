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
        "chief.continue",
        "chief.retry",
    ] {
        let operation: ResourceOperation =
            serde_json::from_str(&format!("\"{name}\"")).expect("known operation");
        assert_eq!(operation.wire_name(), name);
        assert_eq!(serde_json::to_string(&operation).unwrap(), format!("\"{name}\""));
    }
}

#[test]
fn exported_settings_socket_operations_are_resource_wire_names() {
    let schema: serde_json::Value =
        serde_json::from_str(include_str!("../../../../../schemas/settings/settings-schema.json"))
            .expect("generated settings schema");
    let rows = schema["rows"].as_array().expect("settings rows");
    let expected = ["settings.list", "settings.get", "settings.set", "settings.reset"];
    for row in rows {
        let key = row["key"].as_str().expect("settings row key");
        let operations =
            row["surfaces"]["socket"]["operations"].as_array().expect("socket operations");
        let names: Vec<_> = operations
            .iter()
            .map(|operation| operation.as_str().expect("operation name"))
            .collect();
        assert_eq!(names, expected, "{key} socket operations");
        for name in names {
            let operation: ResourceOperation =
                serde_json::from_value(serde_json::Value::String(name.to_owned()))
                    .unwrap_or_else(|error| panic!("{key}: {name}: {error}"));
            assert_eq!(operation.wire_name(), name, "{key} operation wire name");
        }
    }
}
