//! Property tests (OWNERSHIP-PRINCIPLES invariant 5 and the managed guard):
//! replaying an op with the same idempotency key has no further effect; a
//! managed key never changes through any op sequence; reset all leaves
//! kept and managed keys; a JSONC set then remove round-trips the text.

mod common;

use cmux_config::value::value_at;
use cmux_config::{Op, Origin, Schema, State, Target, TeamPolicyLayer, WriteMeta, apply, jsonc};
use common::{file_value, forced, path, sample_value, state};
use proptest::prelude::*;
use serde_json::{Value, json};

const FORCED_KEY: &str = "ui.animationSpeed";
const TEAM_KEY: &str = "layout.stripScrollbar";

fn rows() -> Vec<&'static cmux_config::Row> {
    Schema::embedded().rows.iter().collect()
}

#[derive(Debug, Clone)]
enum Step {
    Set { row: usize, refused_sample: bool, origin: Origin, key: Option<u8> },
    SetRaw { name: u8, value: i64, key: Option<u8> },
    Reset { row: usize, key: Option<u8> },
    ResetAll { key: Option<u8> },
}

fn origin() -> impl Strategy<Value = Origin> {
    prop_oneof![Just(Origin::Cli), Just(Origin::User), Just(Origin::Mcp)]
}

fn step() -> impl Strategy<Value = Step> {
    let count = rows().len();
    let key = proptest::option::of(0u8..6);
    prop_oneof![
        4 => (0..count, any::<bool>(), origin(), key.clone()).prop_map(|(row, refused_sample, origin, key)| Step::Set { row, refused_sample, origin, key }),
        1 => (0u8..3, -5i64..5, key.clone()).prop_map(|(name, value, key)| Step::SetRaw { name, value, key }),
        2 => (0..count, key.clone()).prop_map(|(row, key)| Step::Reset { row, key }),
        1 => key.prop_map(|key| Step::ResetAll { key }),
    ]
}

fn op(step: &Step) -> Op {
    let rows = rows();
    let meta = |origin: Origin, key: &Option<u8>| WriteMeta {
        origin,
        idempotency_key: key.map(|k| format!("k{k}")),
        if_revision: None,
    };
    match step {
        Step::Set { row, refused_sample, origin, key } => {
            let row = rows[*row];
            let value = if *refused_sample {
                row.refuses.first().cloned().unwrap_or(Value::Null)
            } else {
                sample_value(row)
            };
            Op::Set { target: Target::Key(row.key.clone()), value, meta: meta(*origin, key) }
        }
        Step::SetRaw { name, value, key } => Op::Set {
            target: Target::Key(format!("shortcuts.bindings.action{name}")),
            value: json!(value),
            meta: meta(Origin::Cli, key),
        },
        Step::Reset { row, key } => {
            Op::Reset { target: Target::Key(rows[*row].key.clone()), meta: meta(Origin::Cli, key) }
        }
        Step::ResetAll { key } => Op::ResetAll { meta: meta(Origin::Cli, key) },
    }
}

fn start() -> State {
    let initial = r#"{
  // user comment
  "ui": { "animationSpeed": "fast" },
  "layout": { "stripScrollbar": "auto" },
  "appearance": { "theme": "Nord" },
}"#;
    let base = state(initial, forced(&[(FORCED_KEY, json!("off"))]));
    let team = TeamPolicyLayer {
        team_name: "Acme".into(),
        enforced: [(TEAM_KEY.to_string(), json!("always"))].into_iter().collect(),
        ..Default::default()
    };
    apply(&base, Op::TeamPolicySet { layer: team }).unwrap().state
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 96, ..ProptestConfig::default() })]

    #[test]
    fn replay_has_no_further_effect_and_managed_keys_never_change(steps in proptest::collection::vec(step(), 1..24)) {
        let mut current = start();
        let forced_file = file_value(&current, &path(FORCED_KEY));
        let team_file = file_value(&current, &path(TEAM_KEY));
        for step in &steps {
            let op = op(step);
            let Ok(applied) = apply(&current, op.clone()) else { continue };
            let next = applied.state;
            if let Op::Set { meta, .. } | Op::Reset { meta, .. } | Op::ResetAll { meta } = &op
                && meta.idempotency_key.is_some()
            {
                let replay = apply(&next, op.clone()).expect("a replay is never refused");
                prop_assert!(replay.outcome.replayed);
                prop_assert_eq!(&replay.outcome.revision, &applied.outcome.revision);
                prop_assert_eq!(replay.state.revision(), next.revision());
                prop_assert_eq!(replay.state.source(), next.source());
                prop_assert!(replay.write.is_none() && replay.changes.is_empty());
            }
            current = next;
            let root = &current.effective().root;
            prop_assert_eq!(value_at(root, &path(FORCED_KEY)), Some(&json!("off")));
            prop_assert_eq!(value_at(root, &path(TEAM_KEY)), Some(&json!("always")));
            prop_assert_eq!(file_value(&current, &path(FORCED_KEY)), forced_file.clone());
            prop_assert_eq!(file_value(&current, &path(TEAM_KEY)), team_file.clone());
            prop_assert!(current.source().contains("// user comment"));
        }
    }

    #[test]
    fn reset_all_leaves_kept_and_managed_keys(steps in proptest::collection::vec(step(), 0..12)) {
        let mut current = start();
        for step in &steps {
            if let Ok(applied) = apply(&current, op(step)) {
                current = applied.state;
            }
        }
        let kept: Vec<(Vec<String>, Option<Value>)> = rows()
            .into_iter()
            .filter(|row| row.kept_on_reset_all || current.effective().managed_keys.contains_key(&row.key))
            .map(|row| (row.path.clone(), file_value(&current, &row.path)))
            .collect();
        let done = apply(&current, Op::ResetAll { meta: WriteMeta::default() }).unwrap().state;
        for (path, before) in kept {
            prop_assert_eq!(file_value(&done, &path), before, "{:?}", path);
        }
        for row in rows().into_iter().filter(|row| !row.kept_on_reset_all && !done.effective().managed_keys.contains_key(&row.key)) {
            prop_assert_eq!(file_value(&done, &row.path), None, "{}", row.key);
        }
        prop_assert_eq!(file_value(&done, &path("shortcuts.bindings")), None);
    }

    #[test]
    fn jsonc_set_then_remove_round_trips(
        members in proptest::collection::vec((0u8..4, -9i64..9, 0u8..4), 1..6),
        trailing_comma in any::<bool>(),
        new_key in "[a-z]{1,6}",
        nested in any::<bool>(),
        value in -100i64..100,
    ) {
        let source = document(&members, trailing_comma);
        let key = format!("new_{new_key}");
        let target = if nested { vec![key.clone(), "inner".to_string()] } else { vec![key.clone()] };
        let edited = jsonc::set(&source, &target, &json!(value)).unwrap();
        let parsed = jsonc::parse(&edited).unwrap();
        prop_assert_eq!(value_at(&parsed, &target), Some(&json!(value)));
        let removed = jsonc::remove(&edited, &[key]).unwrap();
        for marker in ["// header", "/* about", "// note", "/* block */"] {
            prop_assert_eq!(edited.matches(marker).count(), source.matches(marker).count(), "{}", marker);
            prop_assert_eq!(removed.matches(marker).count(), source.matches(marker).count(), "{}", marker);
        }
        prop_assert_eq!(jsonc::parse(&removed).unwrap(), jsonc::parse(&source).unwrap());
        // A block comment after the last value ends up after the new member
        // (as in Swift), so only then is the text not byte-identical.
        if members.last().map(|member| member.0) != Some(3) {
            prop_assert_eq!(removed, source);
        }
    }
}

/// A JSONC object with distinct keys, comments of every kind and either
/// trailing-comma style.
fn document(members: &[(u8, i64, u8)], trailing_comma: bool) -> String {
    let mut text = String::from("{\n  // header\n");
    let count = members.len();
    for (index, (comment, value, indent)) in members.iter().enumerate() {
        let pad = " ".repeat(2 + usize::from(*indent % 2) * 2);
        if *comment == 1 {
            text.push_str(&format!("{pad}/* about k{index} */\n"));
        }
        let comma = if index + 1 < count || trailing_comma { "," } else { "" };
        let tail = if *comment == 2 {
            " // note"
        } else if *comment == 3 {
            " /* block */"
        } else {
            ""
        };
        text.push_str(&format!("{pad}\"k{index}\": {value}{comma}{tail}\n"));
    }
    text.push_str("}\n");
    text
}
