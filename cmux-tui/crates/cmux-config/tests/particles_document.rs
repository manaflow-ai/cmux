//! `agentPane.display.thinking.glyph` holds a `cmux.particles/1` document (a look's thinking dots,
//! Leo, 2026-11-19: "i guess the particle systems could be an api as well... like the
//! customizations thing?"). The owner checks it with the one validator that checks every scene's
//! `choreography` prop (cmux-app-host `particles::validate`), and a refusal names the first bad
//! path instead of quoting a 30 KB value back.

use cmux_config::Domains;
use cmux_config::refusal::Refusal;
use cmux_config::schema::{Accepted, DomainKind, Row, Schema, Validation, accepts};
use serde_json::{Value, json};

const GLYPH: &str = "agentPane.display.thinking.glyph";

/// The glyph row. Until the Mac export (settings-schema.json, written by SettingsSchemaExport)
/// carries it, the same row drawn from another text row of the section with the source's
/// validation (schemas/settings/source/row-facts.json `domain:particles_document`).
fn glyph_row() -> Row {
    let schema = Schema::embedded();
    if let Some(row) = schema.row(GLYPH) {
        return row.clone();
    }
    let mut row = schema.row("agentPane.display.commandLabels").expect("a text row").clone();
    row.key = GLYPH.to_owned();
    row.path = GLYPH.split('.').map(str::to_owned).collect();
    row.validation = Validation::Domain(DomainKind::ParticlesDocument);
    row.default = None;
    row
}

fn trade() -> Value {
    json!({
        "$schema": "cmux.particles/1",
        "particle": {"shape": "circle", "size": 3.0, "color": "accent", "max": 3},
        "phases": {
            "lone": {"duration": 350, "frames": [{"at": 0, "dots": [[0, 0, 0.6]]}]},
            "trade": {"duration": 1400, "ease": "easeInOut", "frames": [
                {"at": 0, "dots": [[-6.5, 0, 0.6], [0, 0, 1.2], [6.5, 0, 0.6]]},
                {"at": 0.5, "dots": [[-8, 0, 1.0], [0, 0, 0.55], [8, 0, 1.0]]},
                {"at": 1, "dots": [[-6.5, 0, 0.6], [0, 0, 1.2], [6.5, 0, 0.6]]}
            ]}
        },
        "triggers": {"execute": ["trade"], "sendMessage": {"intro": ["lone"], "loop": ["trade"]}, "cycle": ["trade"]}
    })
}

#[test]
fn a_valid_document_is_accepted() {
    assert!(accepts(&glyph_row(), &trade(), &Domains::default()).is_ok());
}

#[test]
fn an_invalid_document_is_refused_with_the_validators_reason() {
    let row = glyph_row();
    let mut bad = trade();
    bad["phases"]["trade"]["frames"][1]["dots"][0][2] = json!(9);
    let Err(refusal) = accepts(&row, &bad, &Domains::default()) else {
        panic!("a scale of 9 is refused");
    };
    let Refusal::InvalidValue { accepted, .. } = &refusal else { panic!("{refusal:?}") };
    let Accepted::Document { schema, reason } = accepted else { panic!("{accepted:?}") };
    assert_eq!(*schema, "cmux.particles/1");
    assert_eq!(reason, "phases.trade.frames[1].dots[0][2]: must be from 0 to 4");
    // The message says where, never the whole document.
    assert_eq!(
        refusal.to_string(),
        format!("{GLYPH} is not a cmux.particles/1 document: {reason}")
    );
    assert_eq!(refusal.data()["accepted"]["reason"], json!(reason));

    let mut unknown_phase = trade();
    unknown_phase["triggers"]["read"] = json!(["orbit"]);
    let reason = accepts(&row, &unknown_phase, &Domains::default()).unwrap_err().to_string();
    assert!(reason.contains("triggers.read"), "{reason}");

    for value in [json!("trade.json"), json!({}), json!(null), json!([trade()])] {
        assert!(accepts(&row, &value, &Domains::default()).is_err(), "{value}");
    }
}
