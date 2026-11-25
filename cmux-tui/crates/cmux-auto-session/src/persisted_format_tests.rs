//! The snapshot manifest crosses an update (cmux-tui/persisted-formats/formats.toml,
//! `auto-session-manifest`). The Cloud store keeps the manifest one build wrote, and the next
//! holder, which may run a newer build, reads it with [`crate::chunks::validate`]. So every
//! shape an older build wrote must still load, and a change to the shape this build writes ships
//! with a fixture of it.
//!
//! Leo, 2026-11-24 (ask-1f9e8b7422): "we need to make sure in the future these kinds of cutovers
//! always have proper migrations. in the future."

use std::collections::BTreeSet;
use std::path::PathBuf;

use serde_json::Value;

use crate::chunks::validate;
use crate::consts::MANIFEST_VERSION;
use crate::wire::{Cwd, Manifest, NativeFile, OpenTool, OpenTurn, QueuedPrompt};

const FIXTURES: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../persisted-formats/auto-session-manifest");

/// `(version, revision, path)` of each fixture, oldest first.
fn fixtures() -> Vec<(u32, u32, PathBuf)> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(FIXTURES).expect("read the auto-session-manifest fixtures") {
        let path = entry.unwrap().path();
        let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or_default().to_owned();
        let Some(rest) = stem.strip_prefix('v') else { continue };
        let (version, revision) = match rest.split_once('-') {
            Some((v, r)) => (v.parse().unwrap(), r.parse().unwrap()),
            None => (rest.parse().unwrap(), 1),
        };
        out.push((version, revision, path));
    }
    out.sort();
    out
}

/// Every key path of a JSON value (`openTurn.tool.name`, `cwd.kind`), so a nested change counts.
fn keys(value: &Value, prefix: &str, out: &mut BTreeSet<String>) {
    match value {
        Value::Object(map) => {
            for (key, inner) in map {
                let path = if prefix.is_empty() { key.clone() } else { format!("{prefix}.{key}") };
                out.insert(path.clone());
                keys(inner, &path, out);
            }
        }
        Value::Array(items) => {
            items.iter().for_each(|item| keys(item, &format!("{prefix}[]"), out))
        }
        _ => {}
    }
}

fn key_set(value: &Value) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    keys(value, "", &mut out);
    out
}

/// Every field set and every option `Some`: the whole shape this build writes.
fn whole_manifest() -> Manifest {
    Manifest {
        v: MANIFEST_VERSION,
        at: 1,
        last_seq: 2,
        harness: "claude".into(),
        harness_session_id: "h".into(),
        cwd: Cwd::Git {
            remote: "r".into(),
            branch: "b".into(),
            base: "0".repeat(40),
            bundle: vec!["a".repeat(64)],
            patch: vec!["b".repeat(64)],
        },
        queue: vec![QueuedPrompt { id: "p".into(), text: "t".into() }],
        draft: "d".into(),
        open_turn: Some(OpenTurn {
            turn_id: "t".into(),
            prompt_id: "p".into(),
            tool: Some(OpenTool { name: "n".into(), args: "{}".into() }),
        }),
        native: vec![NativeFile {
            label: "claude-project".into(),
            path: "p".into(),
            chunks: vec!["c".repeat(64)],
        }],
    }
}

#[test]
fn cmux_next_persisted_auto_session_manifest_every_older_shape_loads() {
    let all = fixtures();
    assert!(
        all.iter().any(|(v, _, _)| *v == MANIFEST_VERSION),
        "no fixture of manifest version {MANIFEST_VERSION} in {FIXTURES}: a version raise ships \
         with a fixture of the new shape (and keeps the old ones)"
    );
    for (version, revision, path) in all {
        let text = std::fs::read_to_string(&path).unwrap();
        let manifest: Manifest = serde_json::from_str(&text).unwrap_or_else(|e| {
            panic!(
                "{}: an older build's manifest (v{version}-{revision}) no longer parses: {e}",
                path.display()
            )
        });
        assert_eq!(
            validate(&manifest),
            Ok(()),
            "{}: the next holder refuses a manifest an older build wrote (v{version}-{revision}). \
             Keep reading the old version, or convert it, before shipping",
            path.display()
        );
    }
}

#[test]
fn cmux_next_persisted_auto_session_manifest_writer_shape_has_a_fixture() {
    let (version, revision, newest) = fixtures().last().expect("fixtures").clone();
    assert_eq!(version, MANIFEST_VERSION, "the newest fixture is not this build's version");
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(&newest).unwrap()).unwrap();
    let written = serde_json::to_value(whole_manifest()).unwrap();
    assert_eq!(
        key_set(&written),
        key_set(&fixture),
        "the manifest this build writes is not the shape of {} (v{version}-{revision}). Add \
         v{version}-<next>.json with the new shape (never edit an old fixture) and keep the old ones \
         loading (cmux-tui/persisted-formats/formats.toml)",
        newest.display()
    );
}
