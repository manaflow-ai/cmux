use super::*;

#[test]
fn every_curated_entry_names_a_schema_row_of_its_kind() {
    let schema = Schema::embedded();
    let listed = features(schema);
    for entry in CURATED {
        assert!(
            listed.iter().any(|f| f.id == entry.id),
            "{} ({}) is not a {} row in the schema",
            entry.id,
            entry.key,
            if entry.on.is_some() { "choice" } else { "toggle" }
        );
    }
}

#[test]
fn no_feature_is_on_by_default_through_its_choice() {
    // A choice feature's "on" is never the default: turning it off resets.
    for feature in features(Schema::embedded()) {
        if !feature.is_toggle() {
            assert_ne!(feature.row.default.as_ref(), Some(&feature.on), "{}", feature.id);
        }
    }
}

#[test]
fn ids_are_unique_and_experiments_are_listed() {
    let list = features(Schema::embedded());
    let mut ids: Vec<_> = list.iter().map(|f| f.id.as_str()).collect();
    let total = ids.len();
    ids.sort_unstable();
    ids.dedup();
    assert_eq!(ids.len(), total);
    assert!(list.iter().any(|f| f.group == "Experiments"));
    assert!(list.iter().any(|f| f.group == "Labs"));
}

#[test]
fn the_gate_is_an_experiment_that_is_off_by_default() {
    let row = Schema::embedded().row(GATE).expect("experiments.appStoreFeatures is a schema row");
    assert!(matches!(row.kind, Kind::Toggle));
    assert_eq!(row.default, Some(Value::Bool(false)));
    assert!(
        features(Schema::embedded()).iter().all(|f| f.row.key != GATE),
        "the gate is not a switch on its own tab"
    );
}

#[test]
fn plan_writes_only_what_changes() {
    let t = Value::Bool(true);
    assert_eq!(plan(&t, true, Some(&Value::Bool(false)), true), Write::Set(t.clone()));
    assert_eq!(plan(&t, true, Some(&t), false), Write::Set(Value::Bool(false)));
    assert_eq!(plan(&t, true, Some(&t), true), Write::Nothing);
    let daily = json!("daily");
    assert_eq!(plan(&daily, false, Some(&json!("none")), true), Write::Set(daily.clone()));
    assert_eq!(plan(&daily, false, Some(&daily), false), Write::Reset);
    // Off while another choice holds: leave the person's choice alone.
    assert_eq!(plan(&daily, false, Some(&json!("desktop")), false), Write::Nothing);
}
