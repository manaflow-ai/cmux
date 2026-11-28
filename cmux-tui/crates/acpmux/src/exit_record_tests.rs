use super::*;
use crate::close_why::{CloseActor, CloseWhy};
use serde_json::{Value, json};

fn meta(tags: Value) -> SessionMeta {
    let mut m: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane-a", "harness": "claude",
        "cwd": "/w/lane-a", "createdAt": 1, "updatedAt": 1, "status": "idle",
        "agentSessionId": "t-1",
    }))
    .unwrap();
    m.tags = serde_json::from_value(tags).unwrap();
    m
}

#[test]
fn the_class_follows_the_outcome_and_the_closer() {
    let lane = meta(json!({"lane.reportsTo": {"value": "coord"}}));
    let class = |why: CloseWhy| ExitClass::of(&CloseRecord::new(why, &lane, 5));
    assert_eq!(class(CloseWhy::by("cli", "x").outcome("done")), ExitClass::Done);
    assert_eq!(class(CloseWhy::by("cli", "x").outcome("dropped")), ExitClass::Dropped);
    assert_eq!(class(CloseWhy::by("harness_exit", "exit 1")), ExitClass::Crashed);
    assert_eq!(class(CloseWhy::by("ttl", "idle")), ExitClass::Killed);
    let plain = meta(json!({}));
    assert_eq!(
        ExitClass::of(&CloseRecord::new(CloseWhy::by("ttl", "idle"), &plain, 5)),
        ExitClass::Dropped
    );
}

#[test]
fn the_record_names_owned_work_and_its_checkpoint() {
    let m = meta(json!({"spawnedBy": {"value": "coord"}, "goal": {"value": "ship exit records"}}));
    let close =
        CloseRecord::new(CloseWhy::actor(CloseActor::new("ttl")).outcome("unfinished"), &m, 42);
    let r = ExitRecord::new(&m, close, vec!["https://github.com/o/r/pull/7".into()]);
    assert_eq!(r.prompt_id(), "exit-s1-42");
    assert_eq!(r.class, ExitClass::Killed);
    assert!(r.owned.any());
    let text = r.text(&[]);
    assert_eq!(
        text,
        "[exit] `lane-a`, which you started, ended killed: unrecorded (closed by ttl). It \
owned: PRs https://github.com/o/r/pull/7; goal \"ship exit records\"; that work is yours now. \
Folder: `/w/lane-a`. Checkpoint: claude transcript `t-1`; read it with `acpmux session tail \
lane-a`."
    );
    let up = r.text(&["mid".into(), "coord".into()]);
    assert!(up.contains("which `mid` < `coord` started (closed, so it comes to you)"), "{up}");
    let v = serde_json::to_value(&r).unwrap();
    assert_eq!(v["class"], "killed");
    assert_eq!(v["owned"]["goal"], "ship exit records");
    assert_eq!(v["transcript"], "t-1");
}

#[test]
fn the_parent_tag_reads_in_order() {
    assert_eq!(parent_tag(&meta(json!({}))), None);
    let m = meta(json!({"lane.reportsTo": {"value": "lead"}, "spawnedBy": {"value": " "}}));
    assert_eq!(parent_tag(&m).as_deref(), Some("lead"));
    let m = meta(json!({"lane.reportsTo": {"value": "lead"}, "mux.parent": {"value": "chief"}}));
    assert_eq!(parent_tag(&m).as_deref(), Some("chief"));
}
