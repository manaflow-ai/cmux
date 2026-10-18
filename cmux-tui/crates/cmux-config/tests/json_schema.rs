//! The editor JSON Schema (`Schema::json_schema`) agrees with the owner's
//! own validation: every sample the settings export accepts passes it, and
//! every portable sample the export refuses fails it (URLs and search templates are checked by the owner
//! only, so the schema only asks for a string there).

use cmux_config::Schema;
use cmux_config::schema::{Kind, Validation};
use cmux_config::value::nest;
use serde_json::{Value, json};

fn generated() -> Value {
    Schema::embedded().json_schema()
}

fn validator() -> jsonschema::Validator {
    jsonschema::validator_for(&generated()).expect("the generated schema compiles")
}

#[test]
fn json_schema_is_a_valid_draft_2020_12_schema() {
    let schema = generated();
    let meta = jsonschema::meta::validate(&schema).map_err(|error| error.to_string());
    assert!(meta.is_ok(), "{meta:?}");
}

#[test]
fn json_schema_passes_every_accepted_sample() {
    let validator = validator();
    let mut failures = Vec::new();
    for row in &Schema::embedded().rows {
        for sample in row.accepts.iter().chain(row.default.iter()) {
            let document = nest(sample.clone(), &row.path);
            if !validator.is_valid(&document) {
                failures.push(format!("{} refuses {sample}", row.key));
            }
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn json_schema_fails_every_portable_refused_sample() {
    let validator = validator();
    let mut failures = Vec::new();
    for row in &Schema::embedded().rows {
        if row.validation != Validation::Portable || matches!(row.kind, Kind::Url | Kind::Text) {
            continue;
        }
        for sample in &row.refuses {
            if validator.is_valid(&nest(sample.clone(), &row.path)) {
                failures.push(format!("{} accepts {sample}", row.key));
            }
        }
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

#[test]
fn json_schema_allows_keys_outside_the_schema() {
    let document = json!({
        "$schema": "./cmux-next.schema.json",
        "actions": { "custom": { "title": "x" } },
        "appearance": { "theme": "light:Catppuccin Latte,dark:Catppuccin Mocha", "glassTransparency": 0.4 },
        "sidebar": { "side": "right", "density": "compact" },
        "terminal": { "fontFamily": "Berkeley Mono", "fontSize": 13 },
    });
    let validator = validator();
    let errors: Vec<String> =
        validator.iter_errors(&document).map(|error| error.to_string()).collect();
    assert!(errors.is_empty(), "{errors:#?}");
}
