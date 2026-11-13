//! `settings.edit` (plans/cmux-next/settings-react.md section 7, items 2 and
//! 3): several edits in one publish (Swift `CmuxConfigFile.apply`), set only
//! when unset (`setUnset`) and remove only when unchanged (`removeUnchanged`).

use cmux_config::{
    Domains, Edit, EditKind, FileRead, MAX_EDITS, ManagedPreferences, Op, Origin, Refusal, Schema,
    State, Target, TeamPolicyLayer, WriteMeta, apply,
};
use serde_json::{Value, json};

fn state(text: &str) -> State {
    state_with(text, ManagedPreferences::default())
}

fn state_with(text: &str, managed: ManagedPreferences) -> State {
    State::new(
        Schema::embedded(),
        FileRead::Text(text.to_string()),
        managed,
        TeamPolicyLayer::default(),
        Domains::default(),
        7,
    )
}

fn user() -> WriteMeta {
    WriteMeta { origin: Origin::User, ..WriteMeta::default() }
}

fn edit(key: &str, kind: EditKind) -> Edit {
    Edit { target: Target::Key(key.to_string()), kind }
}

fn run(
    state: &State,
    edits: Vec<Edit>,
    meta: WriteMeta,
) -> Result<cmux_config::store::Applied, Refusal> {
    apply(state, Op::Edit { edits, meta })
}

fn root(text: &str) -> Value {
    serde_json::from_str(text).expect("the written file is JSON")
}

/// Swift `setSetting` of a renamed row: the new key, the old key's removal and
/// the window background's linked pair go in one publish with one revision.
#[test]
fn several_edits_publish_once_with_one_revision() {
    let before =
        state(r#"{"appearance": {"backdropArt": "munch-scream"}, "layout": {"panePadding": 4}}"#);
    let applied = run(
        &before,
        vec![
            edit("appearance.background", EditKind::Set(json!("daily"))),
            edit("appearance.backdropArt", EditKind::Reset),
            edit("appearance.backgroundOpacity", EditKind::Set(json!(0.5))),
            edit("appearance.backgroundBlur", EditKind::Set(json!("glass"))),
        ],
        user(),
    )
    .expect("the edits apply");
    let written = applied.write.expect("one publish");
    let file = root(&written);
    assert_eq!(file.pointer("/appearance/background"), Some(&json!("daily")), "{written}");
    assert_eq!(file.pointer("/appearance/backdropArt"), None, "{written}");
    assert_eq!(file.pointer("/appearance/backgroundOpacity"), Some(&json!(0.5)));
    assert_eq!(file.pointer("/appearance/backgroundBlur"), Some(&json!("glass")));
    assert_eq!(file.pointer("/layout/panePadding"), Some(&json!(4)), "other keys stay");
    assert_eq!(applied.changes.len(), 1, "one settings-changed event");
    assert_eq!(applied.outcome.revision, 8, "one revision for the whole op");
    assert_eq!(applied.state.revision(), 8);
    assert_eq!(applied.outcome.applied, vec![0, 1, 2, 3]);
    for key in
        ["appearance.background", "appearance.backgroundOpacity", "appearance.backgroundBlur"]
    {
        assert!(
            applied.outcome.keys.iter().any(|changed| changed == key),
            "{key}: {:?}",
            applied.outcome.keys
        );
    }
}

/// One refused edit refuses the op: nothing is written, no revision is used.
#[test]
fn a_refused_edit_writes_nothing() {
    let before = state(r#"{"appearance": {"chromeStyle": "card"}}"#);
    let refused = run(
        &before,
        vec![
            edit("appearance.chromeStyle", EditKind::Reset),
            edit("appearance.density", EditKind::Set(json!("not-a-density"))),
        ],
        user(),
    );
    assert!(matches!(refused, Err(Refusal::InvalidValue { .. })), "{refused:?}");

    let mut managed = ManagedPreferences::default();
    managed.forced.insert("appearance.density".to_string(), json!("compact"));
    let managed = state_with("{}", managed);
    let refused = run(
        &managed,
        vec![
            edit("appearance.chromeStyle", EditKind::Set(json!("card"))),
            edit("appearance.density", EditKind::Set(json!("cozy"))),
        ],
        user(),
    );
    assert!(matches!(refused, Err(Refusal::Managed { .. })), "{refused:?}");

    // The object-overlap rule of settings.set holds inside an edit too.
    let refused = run(&state("{}"), vec![edit("appearance", EditKind::Set(json!({})))], user());
    assert!(matches!(refused, Err(Refusal::InvalidParams { .. })), "{refused:?}");

    // A user-only row stays the person's.
    let mcp = WriteMeta { origin: Origin::Mcp, ..WriteMeta::default() };
    let refused = run(&state("{}"), vec![edit("history.terminalCommands", EditKind::Reset)], mcp);
    assert!(matches!(refused, Err(Refusal::AgentRefused { .. })), "{refused:?}");
}

/// `set_unset` sets only a path the file leaves unset; a stored value, JSON
/// null included, stays.
#[test]
fn set_unset_keeps_a_value_the_file_holds() {
    let before = state(r#"{"appearance": {"chromeStyle": "card", "backgroundBlur": null}}"#);
    let applied = run(
        &before,
        vec![
            edit("appearance.chromeStyle", EditKind::SetUnset(json!("bare"))),
            edit("appearance.backgroundBlur", EditKind::SetUnset(json!("glass"))),
            edit("layout.panePadding", EditKind::SetUnset(json!(12))),
        ],
        user(),
    )
    .expect("the edits apply");
    assert_eq!(applied.outcome.applied, vec![2], "only the unset path is set");
    let file = root(&applied.write.expect("the file changes"));
    assert_eq!(file.pointer("/appearance/chromeStyle"), Some(&json!("card")));
    assert_eq!(file.pointer("/appearance/backgroundBlur"), Some(&Value::Null));
    assert_eq!(file.pointer("/layout/panePadding"), Some(&json!(12)));
}

/// `reset_unchanged` removes a value only while it is the expected one
/// (`1` and `1.0` are one value, as in Swift), and the objects it empties go.
#[test]
fn reset_unchanged_removes_only_the_expected_value() {
    let before = state(
        r#"{"appearance": {"backgroundOpacity": 1.0}, "layout": {"panePadding": 4}, "updates": {"downloadAutomatically": true}}"#,
    );
    let applied = run(
        &before,
        vec![
            edit("appearance.backgroundOpacity", EditKind::ResetUnchanged(json!(1))),
            edit("layout.panePadding", EditKind::ResetUnchanged(json!(8))),
            edit("appearance.chromeStyle", EditKind::ResetUnchanged(json!("flat"))),
        ],
        user(),
    )
    .expect("the edits apply");
    assert_eq!(applied.outcome.applied, vec![0], "a changed or absent value is not removed");
    let written = applied.write.expect("the file changes");
    let file = root(&written);
    assert_eq!(file.get("appearance"), None, "the emptied object goes: {written}");
    assert_eq!(file.pointer("/layout/panePadding"), Some(&json!(4)));
    assert_eq!(file.pointer("/updates/downloadAutomatically"), Some(&json!(true)));

    // The stray-null pass: an expected null removes a stored null only.
    let nulls = state(r#"{"appearance": {"backgroundBlur": null, "chromeStyle": "card"}}"#);
    let applied = run(
        &nulls,
        vec![
            edit("appearance.backgroundBlur", EditKind::ResetUnchanged(Value::Null)),
            edit("appearance.chromeStyle", EditKind::ResetUnchanged(Value::Null)),
        ],
        user(),
    )
    .expect("the edits apply");
    assert_eq!(applied.outcome.applied, vec![0]);
    let file = root(&applied.write.expect("the file changes"));
    assert_eq!(file.pointer("/appearance/backgroundBlur"), None);
    assert_eq!(file.pointer("/appearance/chromeStyle"), Some(&json!("card")));
}

/// A condition reads the file as the edits before it in the same op left it.
#[test]
fn a_condition_sees_the_edits_before_it() {
    let before = state(r#"{"appearance": {"chromeStyle": "card"}}"#);
    let applied = run(
        &before,
        vec![
            edit("appearance.chromeStyle", EditKind::Reset),
            edit("appearance.chromeStyle", EditKind::SetUnset(json!("bare"))),
        ],
        user(),
    )
    .expect("the edits apply");
    assert_eq!(applied.outcome.applied, vec![0, 1]);
    let file = root(&applied.write.expect("the file changes"));
    assert_eq!(file.pointer("/appearance/chromeStyle"), Some(&json!("bare")));
}

/// A conditional edit whose condition does not hold writes nothing, so it is
/// not checked: a pass over many keys does not fail on a managed one that
/// the person changed.
#[test]
fn a_skipped_edit_is_not_refused() {
    let mut managed = ManagedPreferences::default();
    managed.forced.insert("appearance.density".to_string(), json!("compact"));
    let before =
        state_with(r#"{"appearance": {"density": "spacious", "chromeStyle": "card"}}"#, managed);
    let applied = run(
        &before,
        vec![
            edit("appearance.density", EditKind::ResetUnchanged(json!("cozy"))),
            edit("appearance.density", EditKind::SetUnset(json!("cozy"))),
            edit("appearance.chromeStyle", EditKind::ResetUnchanged(json!("card"))),
        ],
        user(),
    )
    .expect("the edits apply");
    assert_eq!(applied.outcome.applied, vec![2]);

    // No condition holds: no write, no revision, still answered.
    let applied = run(
        &before,
        vec![edit("appearance.chromeStyle", EditKind::SetUnset(json!("bare")))],
        user(),
    )
    .expect("the op applies");
    assert_eq!(applied.write, None);
    assert!(applied.changes.is_empty());
    assert_eq!(applied.outcome.revision, 7);
    assert!(applied.outcome.applied.is_empty());
}

/// The same idempotency key and edits replay the outcome (with the applied
/// list); other edits under that key are a conflict.
#[test]
fn an_edit_replays_by_idempotency_key() {
    let meta = WriteMeta { idempotency_key: Some("k1".to_string()), ..user() };
    let edits = vec![
        edit("layout.panePadding", EditKind::SetUnset(json!(12))),
        edit("appearance.chromeStyle", EditKind::SetUnset(json!("card"))),
    ];
    let first = run(&state("{}"), edits.clone(), meta.clone()).expect("the edits apply");
    let replay = run(&first.state, edits, meta.clone()).expect("the replay answers");
    assert!(replay.outcome.replayed);
    assert_eq!(replay.outcome.applied, first.outcome.applied);
    assert_eq!(replay.outcome.revision, first.outcome.revision);
    assert_eq!(replay.write, None, "a replay writes nothing");

    let other = run(&first.state, vec![edit("layout.panePadding", EditKind::Reset)], meta);
    match other {
        Err(Refusal::IdempotencyConflict { committed_operation, .. }) => {
            assert_eq!(committed_operation, "settings.edit");
        }
        other => panic!("expected an idempotency conflict, got {other:?}"),
    }
}

#[test]
fn an_edit_checks_the_revision_the_count_and_the_file() {
    let meta = WriteMeta { if_revision: Some(6), ..user() };
    let refused =
        run(&state("{}"), vec![edit("layout.panePadding", EditKind::Set(json!(4)))], meta);
    assert!(
        matches!(refused, Err(Refusal::RevisionConflict { expected: 6, actual: 7 })),
        "{refused:?}"
    );

    let refused = run(&state("{}"), Vec::new(), user());
    assert!(matches!(refused, Err(Refusal::InvalidParams { .. })), "{refused:?}");
    let many = vec![edit("layout.panePadding", EditKind::Reset); MAX_EDITS + 1];
    let refused = run(&state("{}"), many, user());
    assert!(matches!(refused, Err(Refusal::InvalidParams { .. })), "{refused:?}");

    // A file the person left broken is never rewritten, even by an edit whose
    // condition would not hold.
    let refused = run(
        &state(r#"{"layout": {"panePadding": 4"#),
        vec![edit("layout.panePadding", EditKind::SetUnset(json!(8)))],
        user(),
    );
    assert!(matches!(refused, Err(Refusal::FileUnreadable { .. })), "{refused:?}");
}

/// Comments and unknown keys stay through a multi-edit, like settings.set.
#[test]
fn an_edit_keeps_comments() {
    let text = "{\n  // mine\n  \"custom\": {\"x\": 1},\n  \"layout\": {\"panePadding\": 4}\n}\n";
    let applied = run(
        &state(text),
        vec![
            edit("layout.panePadding", EditKind::ResetUnchanged(json!(4))),
            edit("appearance.chromeStyle", EditKind::Set(json!("card"))),
        ],
        user(),
    )
    .expect("the edits apply");
    let written = applied.write.expect("the file changes");
    assert!(written.contains("// mine"), "{written}");
    assert!(written.contains("\"custom\""), "{written}");
    assert!(!written.contains("panePadding"), "{written}");
}
