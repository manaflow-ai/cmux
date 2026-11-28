//! The person's spare shapes (ask-30d56720f6): the harnesses and models a person used in the last
//! week, read off their own machine's acpmux `pool-spares.json`, and the Cloud machine's
//! `warm-home` command that warms a spare of each beside the default in the reserved home folder
//! (acpmux `hub/pool/reserved.rs`). Leo, 2026-11-25: "we have a warmed machine that has whtaever
//! we need? whatever model/models? depending on whta the user already set up?".
//!
//! The file is acpmux's (`hub/pool/spare.rs` writes it on each pooled session's use); acpmux's own
//! `spare-shapes` verb answers with [`shapes`] too, so the Mac app (over the app FFI,
//! `cloud_warm_home`) and the verb read it one way. On by default; off when `ACPMUX_SPARE_PERSONAL`
//! is 0, false, off or no ([`enabled`]), and the machine's acpmux checks its own copy of the switch.

use std::path::Path;

use serde::{Deserialize, Serialize};

/// The kill switch, as acpmux names it (`config/pool.rs`).
pub const SWITCH: &str = "ACPMUX_SPARE_PERSONAL";
/// acpmux's file in its home.
pub const FILE: &str = "pool-spares.json";
/// A shape used longer ago than this is not the person's any more.
pub const RECENT_MS: u64 = 7 * 24 * 3600 * 1000;
/// Most shapes one warm-home takes (acpmux `MAX_SHAPES`).
pub const MAX: usize = 4;

/// One harness and model a person used.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Shape {
    pub harness: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    harness: String,
    #[serde(default)]
    preset: Option<String>,
    #[serde(default)]
    model: Option<String>,
    used_at_ms: u64,
}

#[derive(Deserialize)]
struct SpareFile {
    #[serde(default)]
    spares: Vec<Entry>,
}

/// Whether personal spares are on for a switch value (absent: on).
pub fn enabled(switch: Option<&str>) -> bool {
    !switch.is_some_and(|v| {
        matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "false" | "off" | "no")
    })
}

/// The shapes in `pool-spares.json`'s bytes at `now_ms`: used in the last week, newest first, at
/// most [`MAX`], folders left out (a Cloud machine warms them in its own reserved folder). A file
/// that does not parse names none.
pub fn shapes(file: &[u8], now_ms: u64) -> Vec<Shape> {
    let mut list = serde_json::from_slice::<SpareFile>(file).map(|f| f.spares).unwrap_or_default();
    list.retain(|e| now_ms.saturating_sub(e.used_at_ms) <= RECENT_MS);
    list.sort_by_key(|entry| std::cmp::Reverse(entry.used_at_ms));
    list.into_iter()
        .take(MAX)
        .map(|e| Shape { harness: e.harness, preset: e.preset, model: e.model })
        .collect()
}

/// [`shapes`] of the file in `acpmux_home` (none when it is missing or the switch is off).
pub fn read(acpmux_home: &Path, now_ms: u64, switch: Option<&str>) -> Vec<Shape> {
    if !enabled(switch) {
        return Vec::new();
    }
    std::fs::read(acpmux_home.join(FILE)).map(|b| shapes(&b, now_ms)).unwrap_or_default()
}

/// A harness id `warm-home` takes: 1 to 64 of `[A-Za-z0-9._-]` (acpmux `parse_shapes`).
fn harness_ok(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

/// A model `warm-home` takes: 1 to 200 printable characters.
fn model_ok(model: &str) -> bool {
    (1..=200).contains(&model.chars().count()) && !model.chars().any(char::is_control)
}

/// `s` in single quotes for `sh`.
fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// The machine-side command that makes the reserved folder of the machine's first home chat and
/// warms its agent there and a spare of each of `shapes` beside it (`cmux-tui acp --json
/// warm-home --wait --shape HARNESS[:MODEL]`), as the work user when the exec runs as root, as
/// [`crate::machine_route::GUEST`] does. A shape `warm-home` would refuse is left out, so one odd
/// entry never costs the warm; it prints nothing when the machine's cmux-tui predates the verb.
pub fn warm_home_command(shapes: &[Shape]) -> String {
    let args: String = shapes
        .iter()
        .filter(|s| harness_ok(&s.harness) && s.model.as_deref().is_none_or(model_ok))
        .take(MAX)
        .map(|s| match &s.model {
            Some(m) => format!(" --shape {}", quote(&format!("{}:{m}", s.harness))),
            None => format!(" --shape {}", quote(&s.harness)),
        })
        .collect();
    format!(
        "c=/home/cmux/.cmux/bin/cmux-tui; [ -x \"$c\" ] || c=cmux-tui; \
if [ \"$(id -u)\" = 0 ] && id cmux >/dev/null 2>&1; then \
set -- setpriv --reuid=cmux --regid=cmux --init-groups env HOME=/home/cmux USER=cmux LOGNAME=cmux; \
else set --; fi; \"$@\" \"$c\" acp --json warm-home --wait{args} 2>/dev/null; true"
    )
}

#[cfg(test)]
#[path = "spare_shapes_tests.rs"]
mod tests;
