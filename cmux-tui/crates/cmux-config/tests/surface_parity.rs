//! The daemon, CLI, MCP tools and native palette consume one exported row
//! registry. Keep the wire operation set explicit so a new surface cannot
//! silently drift from the descriptor that produced it.

use cmux_config::Schema;
use serde_json::Value;

const CLI_AND_SOCKET: &[&str] =
    &["settings.list", "settings.get", "settings.set", "settings.reset"];
const MCP_READ: &[&str] = &["settings.list", "settings.get"];
const MCP_WRITE: &[&str] = &["settings.set", "settings.reset"];
const RESET_ALIASES: &[&str] = &["settings.unset"];

fn operations<'a>(row: &'a Value, surface: &str) -> Vec<&'a str> {
    row["surfaces"][surface]["operations"]
        .as_array()
        .unwrap_or_else(|| panic!("{} has no {surface}.operations", row["key"]))
        .iter()
        .map(|operation| operation.as_str().expect("operation is a string"))
        .collect()
}

fn aliases<'a>(row: &'a Value, surface: &str) -> Vec<&'a str> {
    row["surfaces"][surface]["aliases"]
        .as_array()
        .unwrap_or_else(|| panic!("{} has no {surface}.aliases", row["key"]))
        .iter()
        .map(|alias| alias.as_str().expect("alias is a string"))
        .collect()
}

fn strings<'a>(row: &'a Value, surface: &str, field: &str) -> Vec<&'a str> {
    row["surfaces"][surface][field]
        .as_array()
        .unwrap_or_else(|| panic!("{} has no {surface}.{field}", row["key"]))
        .iter()
        .map(|value| value.as_str().expect("surface entry is a string"))
        .collect()
}

#[test]
fn every_schema_row_declares_matching_surface_operations() {
    let schema = Schema::embedded();
    for row in &schema.rows {
        let surfaces =
            row.raw.get("surfaces").unwrap_or_else(|| panic!("{} has no surfaces", row.key));
        assert_eq!(
            surfaces.as_object().map(|object| object.keys().cloned().collect::<Vec<_>>()),
            Some(vec!["cli".into(), "mcp".into(), "palette".into(), "socket".into()]),
            "{} surface names",
            row.key
        );
        for surface in ["cli", "socket"] {
            assert_eq!(operations(&row.raw, surface), CLI_AND_SOCKET, "{} {surface}", row.key);
            assert_eq!(row.raw["surfaces"][surface]["offered"], true, "{} {surface}", row.key);
            let expected_aliases = if surface == "cli" { RESET_ALIASES } else { &[] };
            assert_eq!(
                aliases(&row.raw, surface),
                expected_aliases,
                "{} {surface} aliases",
                row.key
            );
            if surface == "cli" {
                assert!(
                    strings(&row.raw, surface, "app_operations").is_empty(),
                    "{} {surface} native app methods",
                    row.key
                );
                assert!(
                    strings(&row.raw, surface, "app_aliases").is_empty(),
                    "{} {surface} native app aliases",
                    row.key
                );
            }
        }
        assert_eq!(
            aliases(&row.raw, "socket"),
            &[] as &[&str],
            "{} socket aliases are daemon-only",
            row.key
        );
        assert_eq!(
            strings(&row.raw, "socket", "app_operations"),
            ["settings.get", "settings.set", "settings.reset"],
            "{} app socket methods",
            row.key
        );
        assert_eq!(
            strings(&row.raw, "socket", "app_aliases"),
            RESET_ALIASES,
            "{} app socket aliases",
            row.key
        );
        let palette = &row.raw["surfaces"]["palette"];
        let palette_operations = operations(&row.raw, "palette");
        let palette_offered = palette["offered"].as_bool().unwrap_or(false);
        assert_eq!(
            palette_offered,
            row.raw["surfaces"]["palette"]["row"] != Value::Null,
            "{} palette",
            row.key
        );
        if palette_offered {
            assert_eq!(palette["row"], format!("setting:{}", row.key), "{} palette row", row.key);
            if row.kind.name() == "toggle" {
                assert_eq!(
                    palette_operations,
                    ["palette.toggleSetting"],
                    "{} palette operations",
                    row.key
                );
                assert_eq!(palette["editor"], "toggle", "{} palette editor", row.key);
            } else {
                assert!(
                    palette_operations.is_empty(),
                    "{} palette operations: {palette_operations:?}",
                    row.key
                );
                assert_eq!(palette["editor"], "options", "{} palette editor", row.key);
            }
        }

        let mcp_operations = operations(&row.raw, "mcp");
        let expected_mcp = if row.agent_settable {
            MCP_READ.iter().chain(MCP_WRITE).copied().collect::<Vec<_>>()
        } else {
            MCP_READ.to_vec()
        };
        assert_eq!(mcp_operations, expected_mcp, "{} mcp", row.key);
        assert_eq!(
            aliases(&row.raw, "mcp"),
            if row.agent_settable { RESET_ALIASES } else { &[] },
            "{} mcp aliases",
            row.key
        );
        assert_eq!(row.raw["surfaces"]["mcp"]["offered"], true, "{} mcp", row.key);
    }
}
