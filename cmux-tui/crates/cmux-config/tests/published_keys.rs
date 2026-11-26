//! Every settings key cmux has ever published stays readable: a live row, or
//! an entry in schemas/settings/retired-keys.json that says what became of
//! it. A customization out in the world (a setup, a profile, a theme file, a
//! person's cmux-next.json) may name any of them, and the retired-keys table
//! is how cmux-config migrates it (`cmux_config::migrations`). So a change
//! that deletes a row without a retired entry fails here, in its own PR: the
//! cmux_next_ name puts it in CI's cmux_next_ daemon tests step, and
//! scripts/ci/persisted_formats.py fails a change that drops a line of the record.
//!
//! The record is schemas/settings/published-keys.txt, one key per line,
//! sorted. It only grows: a new row is added with
//! `CMUX_PUBLISHED_KEYS_WRITE=1 cargo test -p cmux-config --test published_keys`.

use std::collections::BTreeSet;
use std::path::PathBuf;

use cmux_config::Schema;
use cmux_config::schema::retired_reason;

const REGEN: &str = "CMUX_PUBLISHED_KEYS_WRITE=1 cargo test -p cmux-config --test published_keys";

fn record() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/settings/published-keys.txt")
}

#[test]
fn cmux_next_persisted_settings_keys_published_or_retired() {
    let path = record();
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let published: BTreeSet<String> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect();
    let schema = Schema::embedded();
    let live: BTreeSet<String> = schema.rows.iter().map(|row| row.key.clone()).collect();

    if std::env::var_os("CMUX_PUBLISHED_KEYS_WRITE").is_some() {
        let mut out = String::from(
            "# Every settings key cmux has published, one per line, sorted. It only grows: a key\n\
             # that is no longer a row needs an entry in retired-keys.json (cmux-config\n\
             # tests/published_keys.rs). Add new rows with:\n",
        );
        out.push_str(&format!("# {REGEN}\n"));
        let retired = cmux_config::schema::retired_keys().iter().map(|(key, _)| key.clone());
        let all: BTreeSet<String> = published.iter().cloned().chain(live).chain(retired).collect();
        for key in &all {
            out.push_str(key);
            out.push('\n');
        }
        std::fs::write(&path, out).expect("write published-keys.txt");
        return;
    }

    let removed: Vec<String> = published
        .iter()
        .filter(|key| {
            let path: Vec<String> = key.split('.').map(str::to_owned).collect();
            schema.row(key).is_none() && retired_reason(&path).is_none()
        })
        .map(|key| {
            format!(
                "removed without a retired-keys.json entry: {key} (add {{key, replaced_by|reason}})"
            )
        })
        .collect();
    assert!(removed.is_empty(), "{}", removed.join("\n"));

    let unrecorded: Vec<&String> = live.difference(&published).collect();
    assert!(
        unrecorded.is_empty(),
        "settings rows not in schemas/settings/published-keys.txt: {unrecorded:?}; run `{REGEN}`"
    );
}
