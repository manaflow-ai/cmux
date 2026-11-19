//! `chat-roots.json` that a newer build wrote keeps what this build cannot read.

use super::*;
use crate::AdapterKind;
use serde_json::{Value, json};

fn spec(harness: AdapterKind, path: &str) -> RootSpec {
    RootSpec { harness, path: PathBuf::from(path), label: None }
}

fn file_json(path: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
}

/// A newer build records a root of a harness kind this build does not know. After a rollback
/// the whole file failed to parse, loaded as empty, and the next recorded root wrote it back
/// with that root alone: every root recorded before was lost.
#[test]
fn a_root_of_an_unknown_harness_kind_keeps_the_other_roots_and_itself() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chat-roots.json");
    let unknown = json!({"harness": "a-newer-kind", "path": "/stores/newer", "label": "n"});
    let written = json!({"version": 1, "roots": [
        {"harness": "claude-code", "path": "/stores/claude"},
        unknown,
        {"harness": "codex", "path": "/stores/codex"},
    ]});
    std::fs::write(&path, serde_json::to_vec(&written).unwrap()).unwrap();

    let mut recorded = RecordedRoots::load(&path);
    assert_eq!(
        recorded.roots(),
        [
            spec(AdapterKind::ClaudeCode, "/stores/claude"),
            spec(AdapterKind::Codex, "/stores/codex")
        ]
    );
    assert!(recorded.record(spec(AdapterKind::Pi, "/stores/pi")).unwrap());

    let saved = file_json(&path);
    let roots = saved["roots"].as_array().unwrap();
    assert!(roots.contains(&unknown), "the save dropped the root it could not read: {saved}");
    assert_eq!(roots.len(), 4, "{saved}");
    let reloaded = RecordedRoots::load(&path);
    assert_eq!(reloaded.roots().len(), 3, "{saved}");
}

/// A file of a newer version is not this build's to rewrite: it is read as no roots, and a
/// root recorded here never replaces it.
#[test]
fn a_file_of_a_newer_version_is_never_written_over() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chat-roots.json");
    let newer =
        br#"{"version":2,"roots":[{"harness":"claude-code","path":"/stores/claude"}],"more":1}"#;
    std::fs::write(&path, newer).unwrap();

    let mut recorded = RecordedRoots::load(&path);
    assert!(recorded.roots().is_empty());
    let _ = recorded.record(spec(AdapterKind::Pi, "/stores/pi"));
    assert_eq!(std::fs::read(&path).unwrap(), newer, "a newer build's file was written over");
}
