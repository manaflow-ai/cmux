//! The terminal-host record crosses an update (cmux-tui/persisted-formats/formats.toml,
//! `terminal-host-record`). A live terminal host outlives the daemon that started it: the next
//! build finds it by the record the old build wrote, so every shape an older build wrote must still
//! load, and a change to the shape this build writes ships with a fixture of it.
//!
//! Leo, 2026-11-24 (ask-1f9e8b7422): "we need to make sure in the future these kinds of cutovers
//! always have proper migrations. in the future."

use super::*;
use std::collections::BTreeSet;

const FIXTURES: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/../../persisted-formats/terminal-host-record");

/// `(version, revision, path)` of each fixture, oldest first: `v4.json` is `(4, 1)`, `v4-2.json`
/// is `(4, 2)`.
fn fixtures() -> Vec<(u32, u32, PathBuf)> {
    let mut out = Vec::new();
    for entry in fs::read_dir(FIXTURES).expect("read the terminal-host-record fixtures") {
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
    value.as_object().expect("a record is a JSON object").keys().cloned().collect()
}

/// Every field set, every option `Some`: the whole shape this build writes. A new field fails to
/// compile here until it is named, and then fails below until the fixture folder has its shape.
fn whole_record() -> TerminalHostRecord {
    TerminalHostRecord {
        record_version: HOST_RECORD_VERSION,
        terminal_id: "0123456789ab4def8123456789abcdef".into(),
        incarnation: "fedcba98765443218fedcba987654321".into(),
        endpoint: "/tmp/endpoint.sock".into(),
        owner_token: "11".repeat(32),
        host_pid: 1,
        host_start_nonce: "22".repeat(32),
        workspace_key: "w".into(),
        supports_set_defaults: true,
        supports_clear_history: true,
        supports_terminate_ack: true,
        supports_input_ack: true,
        supports_terminal_metadata: true,
        supports_clipboard_read: true,
        supports_viewer_size_priority: true,
        supports_pty_custody: true,
        supports_program_status: true,
        supports_shell_activity: true,
        orphan_grace_secs: Some(1),
    }
}

#[test]
fn cmux_next_persisted_terminal_host_record_every_older_shape_loads() {
    let all = fixtures();
    assert!(
        all.iter().any(|(v, _, _)| *v == HOST_RECORD_VERSION),
        "no fixture of terminal-host record version {HOST_RECORD_VERSION} in {FIXTURES}: a version \
         raise ships with a fixture of the new shape (and keeps the old ones)"
    );
    for (version, revision, path) in all {
        let root = std::env::temp_dir().join(format!(
            "cmux-persisted-host-record-{}-{}",
            std::process::id(),
            RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        prepare_private_dir(&root).unwrap();
        let uid = fs::metadata(&root).unwrap().uid();
        let text = fs::read_to_string(&path).unwrap();
        let fixture: serde_json::Value = serde_json::from_str(&text).unwrap();
        let terminal_id = fixture["terminal_id"].as_str().unwrap().to_owned();
        let endpoint = format!("/tmp/cmux-th-{uid}/{terminal_id}.sock");
        let text = text.replace("@ENDPOINT@", &endpoint);
        let record_path = root.join(format!("{terminal_id}.json"));
        fs::write(&record_path, &text).unwrap();
        fs::set_permissions(&record_path, fs::Permissions::from_mode(0o600)).unwrap();

        let loaded = load_terminal_host_records(&root).unwrap();
        let _ = fs::remove_dir_all(&root);
        assert_eq!(
            loaded.len(),
            1,
            "{}: this build does not adopt a host whose record an older build wrote (v{version}-{revision}); \
             keep reading the old shape, or convert it, before shipping",
            path.display()
        );
        let record = &loaded[0].1;
        assert_eq!(record.record_version, version, "{}", path.display());
        // Nothing the old build wrote is dropped on the way in.
        let read_back = serde_json::to_value(record).unwrap();
        let fixture: serde_json::Value = serde_json::from_str(&text).unwrap();
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
fn cmux_next_persisted_terminal_host_record_writer_shape_has_a_fixture() {
    let all = fixtures();
    let (version, revision, newest) = all.last().expect("fixtures").clone();
    assert_eq!(version, HOST_RECORD_VERSION, "the newest fixture is not this build's version");
    let fixture: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&newest).unwrap()).unwrap();
    let written = serde_json::to_value(whole_record()).unwrap();
    assert_eq!(
        keys(&written),
        keys(&fixture),
        "the terminal-host record this build writes is not the shape of {} (v{version}-{revision}). \
         Add v{version}-{next}.json with the new shape (never edit an old fixture) and keep the old ones \
         loading; a change an older build cannot read raises HOST_RECORD_VERSION and keeps reading the old one \
         (cmux-tui/persisted-formats/formats.toml)",
        newest.display(),
        next = revision + 1
    );
}
