//! The settings schema: `Schema::parse` of an export document and its JSON
//! Schema rendering, and `accepts` / `effective_value` of any JSON value
//! against the embedded schema's rows.
//!
//! Input: one selector byte. An even selector parses the rest as a schema
//! document. An odd one reads a little-endian u16 row index (modulo the row
//! count, so every row is reachable), then checks the rest as a value for
//! that row.
#![no_main]

use cmux_config::Domains;
use cmux_config::schema::{Schema, accepts, effective_value};
use cmux_config::value::nest;
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

fuzz_target!(|data: &[u8]| {
    let Some((&selector, rest)) = data.split_first() else {
        return;
    };
    if selector & 1 == 0 {
        let Ok(text) = std::str::from_utf8(rest) else {
            return;
        };
        if let Ok(schema) = Schema::parse(text) {
            let _ = schema.json_schema();
            for row in &schema.rows {
                assert!(schema.row(&row.key).is_some(), "a parsed row is not found by its key");
                let _ = row.kind.name();
            }
        }
        return;
    }
    let [low, high, text @ ..] = rest else {
        return;
    };
    let Ok(text) = std::str::from_utf8(text) else {
        return;
    };
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return;
    };
    let schema = Schema::embedded();
    let row = &schema.rows[usize::from(u16::from_le_bytes([*low, *high])) % schema.rows.len()];
    let domains = [
        Domains::default(),
        Domains::published(vec!["Dark".into()], vec!["Menlo".into()], vec!["Glass".into()]),
    ];
    for domains in &domains {
        let accepted = accepts(row, &value, domains).is_ok();
        let root = nest(value.clone(), &row.path);
        let effective = effective_value(row, &root, domains);
        if accepted {
            assert_eq!(
                effective.as_ref(),
                Some(&value),
                "an accepted value is not the effective one"
            );
        } else {
            assert_eq!(effective, row.default, "a refused value did not fall back to the default");
        }
    }
});
