//! The daemon, CLI, MCP tools and native palette consume one exported row
//! registry. Keep the wire operation set explicit so a new surface cannot
//! silently drift from the descriptor that produced it.

use cmux_config::Schema;
use serde_json::Value;

const CLI_AND_SOCKET: &[&str] = &[
    "settings.list",
    "settings.get",
    "settings.set",
    "settings.reset",
    "settings.unset",
];
const MCP_READ: &[&str] = &["settings.list", "settings.get"];
const MCP_WRITE: &[&str] = &["settings.set", "settings.reset", "settings.unset"];

fn operations<'a>(row: &'a Value, surface: &str) -> Vec<&'a str> {
    row["surfaces"][surface]["operations"]
        .as_array()
        .unwrap_or_else(|| panic!("{} has no {surface}.operations", row["key"]))
        .iter()
        .map(|operation| operation.as_str().expect("operation is a string"))
        .collect()
}

#[test]
fn every_schema_row_declares_matching_surface_operations() {
    let schema = Schema::embedded();
    for row in &schema.rows {
        let surfaces = row.raw.get("surfaces").unwrap_or_else(|| panic!("{} has no surfaces", row.key));
        assert_eq!(
            surfaces.as_object().map(|object| object.keys().cloned().collect::<Vec<_>>()),
            Some(vec!["cli".into(), "mcp".into(), "palette".into(), "socket".into()]),
            "{} surface names",
            row.key
        );
        for surface in ["cli", "socket"] {
            assert_eq!(operations(&row.raw, surface), CLI_AND_SOCKET, "{} {surface}", row.key);
            assert_eq!(row.raw["surfaces"][surface]["offered"], true, "{} {surface}", row.key);
        }
        let palette = &row.raw["surfaces"]["palette"];
        let palette_operations = operations(&row.raw, "palette");
        assert_eq!(palette["offered"], !palette_operations.is_empty(), "{} palette", row.key);
        assert!(
            palette_operations.is_empty() || palette_operations == ["palette.setSetting"],
            "{} palette operations: {palette_operations:?}",
            row.key
        );

        let mcp_operations = operations(&row.raw, "mcp");
        let expected_mcp = if row.agent_settable {
            MCP_READ.iter().chain(MCP_WRITE).copied().collect::<Vec<_>>()
        } else {
            MCP_READ.to_vec()
        };
        assert_eq!(mcp_operations, expected_mcp, "{} mcp", row.key);
        assert_eq!(row.raw["surfaces"]["mcp"]["offered"], true, "{} mcp", row.key);
    }
}
