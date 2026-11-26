//! `doctor.json` crosses an update (cmux-tui/persisted-formats/formats.toml, `doctor-state`): it
//! holds which findings the person dismissed, so the next build reads every shape an older build
//! wrote, and a change to the shape this build writes ships with a fixture of it.

use super::*;
use std::collections::BTreeSet;

const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../persisted-formats/doctor-state");

/// `(version, revision, path)` of each fixture, oldest first.
fn fixtures() -> Vec<(u32, u32, std::path::PathBuf)> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(FIXTURES).expect("read the doctor-state fixtures") {
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

fn keys(value: &serde_json::Value) -> BTreeSet<String> {
    value.as_object().expect("doctor.json is a JSON object").keys().cloned().collect()
}

#[test]
fn cmux_next_persisted_doctor_state_every_older_shape_loads() {
    let all = fixtures();
    assert!(
        all.iter().any(|(v, _, _)| *v == STATE_VERSION),
        "no fixture of doctor.json version {STATE_VERSION} in {FIXTURES}: a version raise ships \
         with a fixture of the new shape (and keeps the old ones)"
    );
    for (version, revision, path) in all {
        let text = std::fs::read_to_string(&path).unwrap();
        let state: State = serde_json::from_str(&text).unwrap_or_else(|error| {
            panic!(
                "{}: this build cannot read doctor.json v{version}-{revision}: {error}",
                path.display()
            )
        });
        assert_eq!(state.version, version, "{}", path.display());
        let fixture: serde_json::Value = serde_json::from_str(&text).unwrap();
        // Every dismissal an older build wrote is still there to read.
        let dismissed = fixture["dismissed"].as_object().unwrap();
        assert_eq!(
            state.dismissed.len(),
            dismissed.len(),
            "{}: dismissals dropped",
            path.display()
        );
        for id in dismissed.keys() {
            assert!(state.dismissed.contains_key(id), "{}: dismissal `{id}` lost", path.display());
        }
        for id in fixture["announced"].as_object().unwrap().keys() {
            assert!(
                state.announced.contains_key(id),
                "{}: announcement `{id}` lost",
                path.display()
            );
        }
    }
}

#[test]
fn cmux_next_persisted_doctor_state_writer_shape_has_a_fixture() {
    let all = fixtures();
    let (version, revision, newest) = all.last().expect("fixtures").clone();
    assert_eq!(version, STATE_VERSION, "the newest fixture is not this build's version");
    let fixture: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&newest).unwrap()).unwrap();
    let written =
        serde_json::to_value(State { version: STATE_VERSION, ..State::default() }).unwrap();
    assert_eq!(
        keys(&written),
        keys(&fixture),
        "doctor.json as this build writes it is not the shape of {} (v{version}-{revision}). Add \
         v{version}-{next}.json with the new shape (never edit an old fixture)",
        newest.display(),
        next = revision + 1
    );
}
