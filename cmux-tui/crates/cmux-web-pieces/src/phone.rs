//! The iPhone app's kill switch file (cmuxterm-hq docs/design/ship-without-update.md, "iOS").
//!
//! The same signed envelope, pinned keys, size bound, channel check and serial floor as the
//! Mac's web pieces file ([`crate::open_as`]), with its own `purpose` and its own pieces, so
//! neither file opens as the other:
//!
//! ```json
//! {"schema": 1, "purpose": "cmux-ios-pieces", "channel": "internal", "serial": 3,
//!  "published_at": 1795340000,
//!  "pieces": {"markdown-web": {"serve": "bundled", "reason": "blank math rows, cmux#1"}}}
//! ```
//!
//! It is published at `cmux-next-web/ota/pieces-ios-<channel>.json`. It is data only: a piece
//! it names is switched **off**, back to the fallback that is already compiled into the app
//! ([`PIECES`]), and a file that no longer names it switches it on again. The file names no
//! URL, no script and no code, and the phone downloads none (App Store Review Guideline 2.5.2,
//! Developer Program License Agreement 3.3.1(B)).
//!
//! Nothing here does I/O: `cmux-mobile-link` fetches the file and keeps the state and the log.

use crate::{Refusal, Switches, open_as, switches_from_json, switches_json, trusted_keys};
use serde_json::{Value, json};
use std::collections::BTreeMap;

/// The payload's `purpose`: the Mac's web pieces file carries another, so neither opens as
/// the other.
pub const PURPOSE: &str = "cmux-ios-pieces";

/// Each piece the phone can switch off, and the fallback built into the app that it then
/// shows. A piece is on this list only when that fallback exists in the app today.
pub const PIECES: &[(&str, &str)] = &[
    (
        "markdown-web",
        "the native markdown renderer; math shows as its TeX source (a display formula in a code card)",
    ),
    (
        "terminal-agent-cli-changes",
        "the terminal's byte stream, as with Settings > Transport > Agent CLI Screen Changes off",
    ),
    (
        "terminal-predictive-echo",
        "the Mac's own echo, as with Settings > Terminal > Predictive echo off",
    ),
];

/// The channel of the build with this bundle identifier, or `None` for a build that reads no
/// switch file: it then makes no request and reads no kept state.
///
/// Only cmux INTERNAL (TestFlight, `dev.cmux.app.internal`) reads one. The App Store app
/// (`com.cmux.app`) stays off until Leo says so (decision d-b295438de2); DEBUG, Demo, Beta
/// and Production builds read none.
#[must_use]
pub fn channel(bundle_id: &str, debug: bool) -> Option<&'static str> {
    match bundle_id {
        "dev.cmux.app.internal" if !debug => Some("internal"),
        _ => None,
    }
}

/// The file's name under `cmux-next-web/ota/`.
#[must_use]
pub fn file_name(channel: &str) -> String {
    format!("pieces-ios-{channel}.json")
}

/// The switches of the phone's file `body`: [`crate::open`] with the phone's purpose and
/// pieces.
pub fn open(
    body: &[u8],
    keys: &[cmux_signed_envelope::Key],
    channel: &str,
    floor: u64,
) -> Result<Switches, Refusal> {
    let names: Vec<&str> = PIECES.iter().map(|(piece, _)| *piece).collect();
    open_as(body, keys, channel, floor, PURPOSE, &names)
}

/// The pieces `switches` turns off, each with its reason.
///
/// Any switch on a piece of [`PIECES`] turns it off: `bundled`, `last-good` (the phone holds
/// no updates, so its last good copy is the built-in one) and a switch this build cannot read
/// (still a switch). A name of no piece this build knows turns nothing off.
#[must_use]
pub fn off(switches: &Switches) -> BTreeMap<&'static str, String> {
    let mut off = BTreeMap::new();
    for (piece, _) in PIECES {
        if let Some(switch) = switches.pieces.get(*piece) {
            off.insert(*piece, switch.reason.clone());
        } else if switches.unknown.iter().any(|unknown| unknown == piece) {
            off.insert(*piece, String::new());
        }
    }
    off
}

/// The names `switches` carries that are no piece of this build (a piece added later). They
/// are kept for the log and change nothing.
#[must_use]
pub fn unknown(switches: &Switches) -> Vec<String> {
    let known = |name: &String| PIECES.iter().any(|(piece, _)| piece == name);
    switches.unknown.iter().filter(|name| !known(name)).cloned().collect()
}

/// One read of the phone's switch file, JSON in and JSON out.
///
/// `input`: `{"envelope": "<the file's text>" | null, "channel": "internal", "floor": 2,
/// "now": 1795340000, "last": {the "switches" of the last reply} | absent}`. A null `envelope`
/// (no file published, the read failed, or a launch that reads only the disk) and a refused
/// file both answer from `last`, the switches the phone last took: a blocked or forged read
/// never switches a piece back on, and never switches one off.
///
/// Reply: `{"taken": bool, "refusal": {"code", "message"} | null, "serial": n, "switches":
/// {...} | null, "off": {"markdown-web": "<reason>"}, "unknown": ["<name>"], "log": {one line
/// for the phone's log}}`. The host stores `serial` as its next `floor` and `switches` as its
/// next `last` only when `taken`.
pub fn evaluate(input: &Value) -> Value {
    evaluate_with(input, &trusted_keys())
}

/// [`evaluate`] against `keys` (the tests' own).
pub fn evaluate_with(input: &Value, keys: &[cmux_signed_envelope::Key]) -> Value {
    let channel = input.get("channel").and_then(Value::as_str).unwrap_or_default();
    let floor = input.get("floor").and_then(Value::as_u64).unwrap_or(0);
    let now = input.get("now").and_then(Value::as_u64).unwrap_or(0);
    let last = input.get("last").and_then(switches_from_json).filter(|s| s.channel == channel);
    let (taken, refusal) = match input.get("envelope").and_then(Value::as_str) {
        None => (None, None),
        Some(text) => match open(text.as_bytes(), keys, channel, floor) {
            Ok(switches) => (Some(switches), None),
            Err(refusal) => (None, Some(refusal)),
        },
    };
    let is_taken = taken.is_some();
    let switches = taken.or(last);
    let off = switches.as_ref().map(off).unwrap_or_default();
    let unknown = switches.as_ref().map(unknown).unwrap_or_default();
    let serial = switches.as_ref().map_or(floor, |s| s.serial.max(floor));
    let refusal_json = refusal
        .as_ref()
        .map_or(Value::Null, |r| json!({"code": r.code(), "message": r.to_string()}));
    let log = json!({
        "at": now, "event": "ios-pieces", "channel": channel,
        "verdict": match (&refusal, is_taken) {
            (Some(refusal), _) => refusal.code(),
            (None, true) => "taken",
            (None, false) => "no_file",
        },
        "serial": serial, "floor": floor,
        "off": off.keys().collect::<Vec<_>>(), "unknown": unknown,
    });
    json!({
        "taken": is_taken, "refusal": refusal_json, "serial": serial,
        "switches": switches.as_ref().map_or(Value::Null, switches_json),
        "off": off, "unknown": unknown, "log": log,
    })
}

#[cfg(test)]
#[path = "phone_tests.rs"]
mod tests;
