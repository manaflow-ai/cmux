//! Ported from Swift `SocketSettingsWriteTests` (the socket stopgap
//! c9cb3b51eea/1f08a54bc4c): every schema row sets, reads back and resets
//! through the owner; a value of the wrong type is `invalid_params`; a
//! managed key is `managed` on every write op.

mod common;

use cmux_config::{ManagedSource, Op, Refusal, Schema, Target, WriteMeta, apply};
use common::{file_value, forced, sample_value, state};
use serde_json::json;

#[test]
fn every_setting_sets_reads_and_resets_through_the_owner() {
    let mut current = state("{}", Default::default());
    for row in &Schema::embedded().rows {
        let value = sample_value(row);
        let target = Target::Key(row.key.clone());
        let before = current.revision();
        let set = apply(
            &current,
            Op::Set { target: target.clone(), value: value.clone(), meta: WriteMeta::default() },
        )
        .unwrap_or_else(|refusal| panic!("{}: {refusal}", row.key));
        assert_eq!(set.state.revision(), before + 1, "{}", row.key);
        assert_eq!(set.changes.len(), 1, "{}", row.key);
        assert!(set.write.is_some(), "{}", row.key);
        current = set.state;
        assert_eq!(file_value(&current, &row.path), Some(value.clone()), "{}", row.key);

        let wrong = apply(
            &current,
            Op::Set {
                target: target.clone(),
                value: json!({"wrong": true}),
                meta: WriteMeta::default(),
            },
        );
        let refusal = wrong.expect_err(&format!("{} accepted a value of the wrong type", row.key));
        assert_eq!(refusal.code(), "invalid_params", "{}", row.key);
        assert_eq!(refusal.data()["kind"], json!(row.kind.name()), "{}", row.key);

        current = apply(&current, Op::Reset { target, meta: WriteMeta::default() }).unwrap().state;
        assert_eq!(file_value(&current, &row.path), None, "{}", row.key);
    }
    assert_eq!(
        cmux_config::jsonc::parse(current.source()).unwrap(),
        json!({}),
        "resets pruned every emptied object"
    );
}

#[test]
fn a_managed_key_is_refused_on_every_write_op() {
    let current = state("{}", forced(&[("appearance.density", json!("compact"))]));
    let target = Target::Key("appearance.density".to_string());
    let ops = [
        Op::Set { target: target.clone(), value: json!("comfortable"), meta: WriteMeta::default() },
        Op::Reset { target, meta: WriteMeta::default() },
        // A raw ancestor write would replace the managed key too.
        Op::Set {
            target: Target::Key("appearance".into()),
            value: json!({}),
            meta: WriteMeta::default(),
        },
        Op::Reset { target: Target::Path(vec!["appearance".into()]), meta: WriteMeta::default() },
    ];
    for op in ops {
        let refusal =
            apply(&current, op.clone()).expect_err(&format!("{op:?} wrote a managed key"));
        assert_eq!(refusal.code(), "managed", "{op:?}");
        assert_eq!(
            refusal,
            Refusal::Managed { key: "appearance.density".into(), source: ManagedSource::Device }
        );
        assert_eq!(
            refusal.data()["reason"],
            json!("appearance.density is managed by your organization")
        );
        assert_eq!(refusal.data()["source"], json!("mdm"));
    }
}
