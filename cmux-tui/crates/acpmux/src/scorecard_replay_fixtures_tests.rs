//! RFD 0161's replay in CI: every log in `data/scorecard-replay/` replays to the violation counts
//! `expected.json` names for it, and each of the five invariants has a log that breaks it.
//!
//! `real-session.ndjson` is a recorded Claude Code lane (221 main-loop calls, five compactions,
//! 2026-11-26) cut to the kinds the replay reads, with paths and MCP tool names hashed, text
//! bodies replaced by at most 256 filler characters and times shifted. Each `seeded-*.ndjson` is
//! its first 40 calls with one invariant broken at the 20th. A change to the daemon or Claude Code
//! that moves a count fails here; a new real log is one more file and one more `expected.json` entry.

use super::*;
use crate::store::MemoryStore;
use std::collections::BTreeSet;
use std::path::Path;

fn load(path: &Path) -> MemoryStore {
    let store = MemoryStore::default();
    let meta = json!({
        "schema": crate::store::META_SCHEMA, "id": "f", "name": "fixture", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    });
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let text = std::fs::read_to_string(path).unwrap();
    for (n, line) in text.lines().enumerate().filter(|(_, l)| !l.trim().is_empty()) {
        let r: EventRecord = serde_json::from_str(line)
            .unwrap_or_else(|e| panic!("{}:{}: {e}", path.display(), n + 1));
        store.append("f", &r).unwrap();
    }
    store
}

fn counts(r: &Replay) -> Value {
    let mut out = serde_json::Map::new();
    for (_, name) in CHECKED {
        let n = r.sessions[0].violations.iter().filter(|v| v.name == *name).count();
        out.insert((*name).into(), json!(n));
    }
    Value::Object(out)
}

#[test]
fn every_fixture_replays_to_its_expected_violations() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("data/scorecard-replay");
    let expected: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("expected.json")).unwrap()).unwrap();
    let expected = expected.as_object().unwrap();
    let mut files: Vec<String> = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.ends_with(".ndjson"))
        .collect();
    files.sort();
    assert!(files.len() >= 6, "{files:?}");

    let mut wrong = vec![];
    let mut broken = BTreeSet::new();
    for f in &files {
        let r = replay(&load(&dir.join(f)), &["f".into()]).unwrap();
        assert_eq!(r.sessions.len(), 1, "{f}: {:?}", r.missing);
        let got = counts(&r);
        for (_, name) in CHECKED {
            if got[*name].as_u64() > Some(0) {
                broken.insert(*name);
            }
        }
        match expected.get(f) {
            Some(want) if *want == got => {}
            want => wrong.push(format!(
                "{f}: expected {}, got {got}; violations: {:#?}",
                want.map_or("no entry".into(), |w| w.to_string()),
                r.sessions[0].violations
            )),
        }
    }
    for name in expected.keys().filter(|k| !files.contains(k)) {
        wrong.push(format!("expected.json names {name}, which is not in {}", dir.display()));
    }
    assert!(wrong.is_empty(), "{}", wrong.join("\n"));
    for (n, name) in CHECKED {
        assert!(broken.contains(name), "no fixture breaks invariant {n} ({name})");
    }
}
