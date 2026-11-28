use super::*;
use std::cell::Cell;
use std::collections::BTreeMap;

use serde_json::json;

use crate::store::SessionMeta;

fn meta(cwd: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane", "harness": "claude",
        "cwd": cwd, "createdAt": 1, "updatedAt": 1, "status": "idle",
    }))
    .unwrap()
}

/// One start of `meta`'s agent: its tool listing read (or derived, counted in `derives`), and
/// what it recorded kept on the meta, as `note_launch` keeps it.
fn start(on: bool, meta: &mut SessionMeta, derives: &Cell<u32>) {
    let cwd = meta.cwd.clone();
    let all = all_tools_with(on, meta.manifest.as_ref(), &cwd, || {
        derives.set(derives.get() + 1);
        true
    });
    let servers = json!([{"name": "cmux"}, {"name": "cmux-agent-memory"}]);
    if let Some(m) = to_record(on, meta.manifest.as_ref(), &cwd, all, Some(&servers)) {
        meta.manifest = Some(m);
    }
}

/// A move: the bundle carries `session.json`, and the target writes the chat's folder there
/// into it (`transfer_in.rs`), rebinding the manifest.
fn moved(meta: &SessionMeta, there: &str) -> SessionMeta {
    let mut value = serde_json::to_value(meta).unwrap();
    value["cwd"] = json!(there);
    rebind(&mut value, there);
    serde_json::from_value(value).unwrap()
}

/// A fork in `cwd`: its meta copies its parent's manifest (`hub/fork.rs`).
fn forked(parent: &SessionMeta, cwd: &str) -> SessionMeta {
    let mut fork = meta(cwd);
    fork.manifest = for_fork(parent.manifest.as_ref(), std::path::Path::new(cwd));
    fork
}

/// Start, move, start there, fork there, start the fork: how many starts derived the tools.
fn lifecycle(on: bool) -> (u32, u32, u32) {
    let derives = Cell::new(0);
    let mut chat = meta("/home/a/repo");
    start(on, &mut chat, &derives);
    let first = derives.get();
    let mut there = moved(&chat, "/home/b/checkouts/repo");
    start(on, &mut there, &derives);
    let after_move = derives.get() - first;
    let mut fork = forked(&there, "/home/b/checkouts/repo");
    start(on, &mut fork, &derives);
    let after_fork = derives.get() - first - after_move;
    (first, after_move, after_fork)
}

#[test]
fn moves_and_forks_re_deriving_the_tools_before_and_after() {
    // Off (today): every start derives, the first and each one after a move or a fork.
    assert_eq!(lifecycle(false), (1, 1, 1));
    // On: the first start derives and records; the move and the fork read the record.
    assert_eq!(lifecycle(true), (1, 0, 0));
}

#[test]
fn off_records_nothing_and_an_old_session_json_reads_without_one() {
    let derives = Cell::new(0);
    let mut chat = meta("/r");
    start(false, &mut chat, &derives);
    assert_eq!(chat.manifest, None);
    let saved = serde_json::to_value(&chat).unwrap();
    assert!(saved.get("manifest").is_none(), "an off daemon writes the same session.json");
}

#[test]
fn the_record_holds_what_the_first_start_used_and_is_kept_once() {
    let derives = Cell::new(0);
    let mut chat = meta("/r");
    start(true, &mut chat, &derives);
    let m = chat.manifest.clone().unwrap();
    assert_eq!(m.folder, std::path::PathBuf::from("/r"));
    assert!(m.all_tools);
    assert_eq!(m.servers, vec!["cmux".to_owned(), "cmux-agent-memory".to_owned()]);
    start(true, &mut chat, &derives);
    assert_eq!(derives.get(), 1);
    assert_eq!(chat.manifest, Some(m));
}

#[test]
fn a_fork_into_another_folder_derives_its_own() {
    let derives = Cell::new(0);
    let mut chat = meta("/r");
    start(true, &mut chat, &derives);
    let mut fork = forked(&chat, "/elsewhere");
    assert_eq!(fork.manifest, None);
    start(true, &mut fork, &derives);
    assert_eq!(derives.get(), 2);
    assert_eq!(fork.manifest.unwrap().folder, std::path::PathBuf::from("/elsewhere"));
}

#[test]
fn a_folder_that_changed_under_the_record_is_derived_again() {
    let calls = Cell::new(0);
    let kept = SessionManifest { folder: "/old".into(), all_tools: true, servers: Vec::new() };
    let all = all_tools_with(true, Some(&kept), std::path::Path::new("/new"), || {
        calls.set(calls.get() + 1);
        false
    });
    assert!(!all);
    assert_eq!(calls.get(), 1);
}

/// One Claude Code start of `meta`'s agent through its command build: the hub marks the profile
/// env, the build reads the mark or derives (counted in `derives`), and the first start records.
fn claude_start(on: bool, meta: &mut SessionMeta, derives: &Cell<u32>) {
    let cwd = meta.cwd.clone();
    let mut env = BTreeMap::new();
    mark_with(on, &mut env, meta.manifest.as_ref(), &cwd);
    let all = claude_all_tools(&env, || {
        derives.set(derives.get() + 1);
        true
    });
    if let Some(m) = to_record(on, meta.manifest.as_ref(), &cwd, all, None) {
        meta.manifest = Some(m);
    }
}

#[test]
fn claude_stdio_moves_and_forks_re_deriving_before_and_after() {
    for (on, want) in [(false, (1, 1, 1)), (true, (1, 0, 0))] {
        let derives = Cell::new(0);
        let mut chat = meta("/home/a/repo");
        claude_start(on, &mut chat, &derives);
        let first = derives.get();
        let mut there = moved(&chat, "/home/b/checkouts/repo");
        claude_start(on, &mut there, &derives);
        let after_move = derives.get() - first;
        let mut fork = forked(&there, "/home/b/checkouts/repo");
        claude_start(on, &mut fork, &derives);
        let after_fork = derives.get() - first - after_move;
        assert_eq!((first, after_move, after_fork), want, "switch on: {on}");
    }
}

#[test]
fn the_mark_holds_only_for_its_folder_and_replaces_a_profiles_own() {
    let m = SessionManifest { folder: "/repo".into(), all_tools: false, servers: Vec::new() };
    let mut env = BTreeMap::from([(RECORDED_ENV.to_owned(), "1".to_owned())]);
    mark_with(true, &mut env, Some(&m), std::path::Path::new("/repo"));
    assert_eq!(env.get(RECORDED_ENV).map(String::as_str), Some("0"));
    // The recorded answer wins without reading settings.
    assert!(!claude_all_tools(&env, || panic!("derived although marked")));
    mark_with(true, &mut env, Some(&m), std::path::Path::new("/elsewhere"));
    assert!(env.get(RECORDED_ENV).is_none());
    mark_with(false, &mut env, Some(&m), std::path::Path::new("/repo"));
    assert!(env.get(RECORDED_ENV).is_none());
}
