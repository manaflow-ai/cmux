//! A row keeps its exported JSON as compact text, not as parsed values (every
//! daemon holds the whole schema). `Row::raw` gives back exactly the row the
//! export has, for `settings.schema`, `settings.list` and the MCP tools.

use cmux_config::Schema;
use serde_json::Value;

#[test]
fn every_embedded_row_gives_back_its_exported_json() {
    let exported: Value =
        serde_json::from_str(include_str!("../../../../schemas/settings/settings-schema.json"))
            .expect("the settings export parses");
    let exported = exported["rows"].as_array().expect("rows");
    let rows = &Schema::embedded().rows;
    assert_eq!(rows.len(), exported.len());
    for (row, exported) in rows.iter().zip(exported) {
        assert_eq!(&row.raw(), exported, "{}", row.key);
    }
}
