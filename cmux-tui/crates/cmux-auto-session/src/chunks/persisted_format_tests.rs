//! The snapshot manifest crosses an update (cmux-tui/persisted-formats/formats.toml,
//! `auto-session-manifest`). The Cloud keeps a chat's manifest until another holder takes the
//! chat over, and that holder may run a newer build than the one that wrote it. So every shape an
//! older build wrote must still pass [`validate`] and read back whole, and a change to the shape
//! this build writes ships with a fixture of it.

use std::collections::BTreeSet;
use std::path::PathBuf;

use serde_json::Value;

use super::*;
use crate::wire::{Cwd, NativeFile, OpenTool, OpenTurn, QueuedPrompt};

const FIXTURES: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../persisted-formats/auto-session-manifest");

/// `(version, revision, path)` of each fixture, oldest first: `v1.json` is `(1, 1)`, `v1-2.json`
/// is `(1, 2)`.
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

fn keys(value: &Value) -> BTreeSet<String> {
    value.as_object().expect("a manifest is a JSON object").keys().cloned().collect()
}

/// Every field set, every option `Some`, every list filled: the whole shape this build writes. A
/// new field fails to compile here until it is named, and then fails below until the fixture
/// folder has its shape.
fn whole_manifest() -> Manifest {
    Manifest {
        v: MANIFEST_VERSION,
        at: 1,
        last_seq: 2,
        harness: "claude".into(),
        harness_session_id: "h".into(),
        cwd: Cwd::Folder { tar: vec![name_of(b"a")] },
        queue: vec![QueuedPrompt { id: "p".into(), text: "t".into() }],
        draft: "d".into(),
        open_turn: Some(OpenTurn {
            turn_id: "t".into(),
            prompt_id: "p".into(),
            tool: Some(OpenTool { name: "n".into(), args: "a".into() }),
        }),
        native: vec![NativeFile {
            label: "claude-project".into(),
            path: "p".into(),
            chunks: vec![name_of(b"b")],
        }],
    }
}

#[test]
fn cmux_next_persisted_auto_session_manifest_every_older_shape_loads() {
    let all = fixtures();
    assert!(
        all.iter().any(|(v, _, _)| *v == MANIFEST_VERSION),
        "no fixture of snapshot manifest version {MANIFEST_VERSION} in {FIXTURES}: a version raise \
         ships with a fixture of the new shape (and keeps the old ones)"
    );
    for (version, revision, path) in all {
        let text = std::fs::read_to_string(&path).unwrap();
        let manifest: Manifest = serde_json::from_str(&text).unwrap_or_else(|err| {
            panic!(
                "{}: this build does not read a manifest an older build wrote (v{version}-{revision}): \
                 {err}. Keep reading the old shape, or convert it, before shipping",
                path.display()
            )
        });
        assert_eq!(
            validate(&manifest),
            Ok(()),
            "{}: a new holder refuses the snapshot an older build left in the Cloud \
             (v{version}-{revision}). Keep reading the old version before shipping",
            path.display()
        );
        assert_eq!(manifest.v, version, "{}", path.display());
        // Nothing the old build wrote is dropped on the way in.
        let read_back = serde_json::to_value(&manifest).unwrap();
        let fixture: Value = serde_json::from_str(&text).unwrap();
        for (key, value) in fixture.as_object().unwrap() {
            assert_eq!(
                read_back.get(key),
                Some(value),
                "{}: field `{key}` does not survive a read by this build",
                path.display()
            );
        }
    }
}

#[test]
fn cmux_next_persisted_auto_session_manifest_writer_shape_has_a_fixture() {
    let all = fixtures();
    let (version, revision, newest) = all.last().expect("fixtures").clone();
    assert_eq!(version, MANIFEST_VERSION, "the newest fixture is not this build's version");
    let fixture: Value = serde_json::from_str(&std::fs::read_to_string(&newest).unwrap()).unwrap();
    let written = serde_json::to_value(whole_manifest()).unwrap();
    assert_eq!(
        keys(&written),
        keys(&fixture),
        "the snapshot manifest this build writes is not the shape of {} (v{version}-{revision}). \
         Add v{version}-{next}.json with the new shape (never edit an old fixture) and keep the old \
         ones loading; raising MANIFEST_VERSION also needs validate to keep reading the old version \
         (cmux-tui/persisted-formats/formats.toml)",
        newest.display(),
        next = revision + 1
    );
}
