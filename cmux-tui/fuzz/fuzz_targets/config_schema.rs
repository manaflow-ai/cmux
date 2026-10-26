//! The settings schema: `Schema::parse` of an export document and its JSON
//! Schema rendering, and `accepts` / `effective_value` of any JSON value
//! against the embedded schema's rows.
//!
//! Input: one selector byte, then JSON text. Even selectors parse the text as
//! a schema document; odd ones check it as a value for row `selector / 2`.
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
    let Ok(text) = std::str::from_utf8(rest) else {
        return;
    };
    if selector & 1 == 0 {
        if let Ok(schema) = Schema::parse(text) {
            let _ = schema.json_schema();
            for row in &schema.rows {
                assert!(schema.row(&row.key).is_some(), "a parsed row is not found by its key");
                let _ = row.kind.name();
            }
        }
        return;
    }
    let Ok(value) = serde_json::from_str::<Value>(text) else {
        return;
    };
    let schema = Schema::embedded();
    let row = &schema.rows[usize::from(selector >> 1) % schema.rows.len()];
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
