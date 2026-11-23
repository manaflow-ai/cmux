//! The per-piece switch file of cmux's web updates (cmuxterm-hq
//! docs/design/ship-without-update.md, plans/cmux-next/web-ota.md).
//!
//! A web update is one signed tree with several independent pieces ([`PIECES`]): the agent
//! pane, the pages, Agent Activity, the viewers and the inspector. The switch file says, per
//! piece, what an app that follows the channel serves instead of the newest update, and which
//! whole updates it never serves:
//!
//! ```json
//! {"schema": 1, "purpose": "cmux-web-pieces", "channel": "every-merge", "serial": 7,
//!  "published_at": 1795340000,
//!  "pieces": {"agent-pane": {"serve": "last-good", "reason": "composer loses drafts, cmux#1"}},
//!  "refuse": ["<update key, 64 hex>"]}
//! ```
//!
//! It travels in cmux's signed envelope (`cmux-signed-envelope`, signed by
//! scripts/cmux-next/web-ota-pointer.py with the web update key) at
//! `cmux-next-web/ota/pieces-<channel>.json`. [`open`] reads it: a signature by a pinned key
//! ([`trusted_keys`]) before any field, then its `purpose`, its channel and its `serial`,
//! which never goes back, so a replayed old file cannot switch a piece back in. [`plan`]
//! turns it and the updates the app holds into what each piece serves. Nothing here does
//! I/O: the host fetches the file, keeps the serial and the log line ([`evaluate`] gives
//! both), and serves the folders.
//!
//! Only web code moves this way: a piece is HTML, JavaScript and CSS a web view loads. The
//! file names no URL and no native code, on any platform.

use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

/// The payload schema [`open`] reads.
pub const SCHEMA: u64 = 1;
/// The payload's `purpose`: no other signed cmux file carries it, so none opens as this one.
pub const PURPOSE: &str = "cmux-web-pieces";
/// A switch file is a few hundred bytes; a host reads no more than this.
pub const MAX_BYTES: usize = 64 * 1024;

/// Each piece and the folder (or file) it is inside an update, the repository layout of
/// `build-web-bundles.sh --out-root`: scripts/cmux-next/web-bundle-key.py `OUTPUTS`, in its
/// order (the test `pieces_are_the_web_bundle_outputs` reads the script).
pub const PIECES: &[(&str, &str)] = &[
    (
        "agent-pane",
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane",
    ),
    (
        "pages",
        "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages",
    ),
    (
        "agent-activity",
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity",
    ),
    ("webviews-app", "Resources/markdown-viewer/webviews-app"),
    (
        "inspector",
        "Native/OptChat/optchat-chief/inspector/index.html",
    ),
];

/// The keys a switch file may be signed with: `(id, base64 raw ed25519 key)`. The same key as
/// Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json (the test
/// `keys_match_the_web_update_keys` keeps them equal). To rotate, add the next key to both,
/// ship it in a nightly, then switch the CI secret.
pub const KEYS: &[(&str, &str)] = &[(
    "e5d7bbcacc70703d",
    "uroy2ajE6JWnMjkx3FNdn88SJN4DCMfLpqZjkwx45WY=",
)];

/// The trusted keys of [`KEYS`], decoded.
pub fn trusted_keys() -> Vec<cmux_signed_envelope::Key> {
    use base64::Engine as _;
    KEYS.iter()
        .filter_map(|(id, b64)| {
            let raw = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
            let raw: [u8; 32] = raw.try_into().ok()?;
            Some(((*id).to_owned(), raw))
        })
        .collect()
}

/// What a switched piece serves instead of the newest update.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Serve {
    /// The web the app shipped with.
    Bundled,
    /// The newest update the app still holds that is not refused; the bundle when none.
    LastGood,
}

/// One piece's switch.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Switch {
    pub serve: Serve,
    /// Why, for the log and the status (an issue or PR).
    #[serde(default)]
    pub reason: String,
}

#[derive(Deserialize)]
struct Payload {
    schema: u64,
    #[serde(default)]
    purpose: String,
    channel: String,
    serial: u64,
    #[serde(default)]
    published_at: u64,
    #[serde(default)]
    pieces: BTreeMap<String, Value>,
    #[serde(default)]
    refuse: Vec<String>,
}

/// A verified switch file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Switches {
    pub channel: String,
    /// Counts publishes; an app never takes a lower one than the last it took.
    pub serial: u64,
    pub published_at: u64,
    /// The switched pieces of [`PIECES`]; a piece not named serves the newest update.
    pub pieces: BTreeMap<String, Switch>,
    /// Updates (their keys) never served, whole.
    pub refuse: BTreeSet<String>,
    /// Names the file switched that this build does not know (a piece added later), or whose
    /// switch it cannot read. Such a piece serves the bundle: a switch this build cannot
    /// read is still a switch.
    pub unknown: Vec<String>,
}

/// Why a switch file was not taken. The app then keeps the switches it last took.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// Larger than [`MAX_BYTES`].
    TooLarge(usize),
    /// Not an envelope, or no signature by a pinned key.
    Unsigned(String),
    Malformed(String),
    /// A signed cmux file of another kind.
    WrongPurpose(String),
    WrongChannel(String),
    /// Older than the last file taken (a replay).
    Stale {
        serial: u64,
        floor: u64,
    },
}

impl Refusal {
    /// A short stable code for the log.
    pub fn code(&self) -> &'static str {
        match self {
            Self::TooLarge(_) => "too_large",
            Self::Unsigned(_) => "unsigned",
            Self::Malformed(_) => "malformed",
            Self::WrongPurpose(_) => "wrong_purpose",
            Self::WrongChannel(_) => "wrong_channel",
            Self::Stale { .. } => "stale",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TooLarge(size) => write!(f, "the switch file is {size} bytes"),
            Self::Unsigned(why) | Self::Malformed(why) => f.write_str(why),
            Self::WrongPurpose(purpose) => write!(f, "the payload's purpose is {purpose:?}"),
            Self::WrongChannel(channel) => write!(f, "the payload is for channel {channel:?}"),
            Self::Stale { serial, floor } => {
                write!(
                    f,
                    "serial {serial} is older than the last one taken ({floor})"
                )
            }
        }
    }
}

fn is_key(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The switches of the envelope `body` when a `keys` signature covers it, it is `channel`'s
/// switch file and its serial is at least `floor` (the serial of the last file taken; the
/// same file read again is taken again).
pub fn open(
    body: &[u8],
    keys: &[cmux_signed_envelope::Key],
    channel: &str,
    floor: u64,
) -> Result<Switches, Refusal> {
    if body.len() > MAX_BYTES {
        return Err(Refusal::TooLarge(body.len()));
    }
    let payload = cmux_signed_envelope::open(body, keys).map_err(Refusal::Unsigned)?;
    let payload: Payload = serde_json::from_slice(&payload)
        .map_err(|e| Refusal::Malformed(format!("the payload does not parse: {e}")))?;
    if payload.purpose != PURPOSE {
        return Err(Refusal::WrongPurpose(payload.purpose));
    }
    if payload.schema != SCHEMA {
        return Err(Refusal::Malformed(format!(
            "unknown payload schema {}",
            payload.schema
        )));
    }
    if payload.channel != channel {
        return Err(Refusal::WrongChannel(payload.channel));
    }
    if payload.serial < floor {
        return Err(Refusal::Stale {
            serial: payload.serial,
            floor,
        });
    }
    if let Some(bad) = payload.refuse.iter().find(|key| !is_key(key)) {
        return Err(Refusal::Malformed(format!(
            "refuse names {bad:?}, not an update key"
        )));
    }
    let mut pieces = BTreeMap::new();
    let mut unknown = Vec::new();
    for (name, value) in payload.pieces {
        match (piece_of(&name), serde_json::from_value::<Switch>(value)) {
            // A finer id (`pages/settings`) switches its whole piece in this build; of several
            // switches on one piece the bundle wins over the last good update.
            (Some(piece), Ok(switch)) => {
                let weaker = matches!(
                    pieces.get(piece),
                    Some(Switch {
                        serve: Serve::Bundled,
                        ..
                    })
                ) || (pieces.contains_key(piece)
                    && matches!(switch.serve, Serve::LastGood));
                if !weaker {
                    pieces.insert(piece.to_owned(), switch);
                }
            }
            // A switch this build cannot read, on a piece it knows: the whole piece.
            (Some(piece), Err(_)) => unknown.push(piece.to_owned()),
            (None, _) => unknown.push(name),
        }
    }
    unknown.sort();
    unknown.dedup();
    Ok(Switches {
        channel: payload.channel,
        serial: payload.serial,
        published_at: payload.published_at,
        pieces,
        refuse: payload.refuse.into_iter().collect(),
        unknown,
    })
}

/// The piece a switch name is about: the piece itself (`pages`) or a finer id under it
/// (`pages/settings`, `agent-pane/pr-49884`), which a build that cannot switch that finely
/// takes as the whole piece. None for a name of no piece this build knows.
#[must_use]
pub fn piece_of(name: &str) -> Option<&'static str> {
    PIECES.iter().map(|(piece, _)| *piece).find(|piece| {
        name.strip_prefix(piece)
            .is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
    })
}

/// Where a piece is served from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Source {
    /// The app's own bundle.
    Bundled,
    /// The kept update with this key.
    Update(String),
}

impl Source {
    fn json(&self) -> Value {
        match self {
            Self::Bundled => Value::Null,
            Self::Update(key) => json!(key),
        }
    }
}

/// What the app serves under a switch file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    /// Every piece of [`PIECES`], in its order.
    pub pieces: Vec<(&'static str, Source)>,
    /// Whether the active update is refused: the app rolls back and never takes it again.
    pub refused_active: bool,
}

impl Plan {
    /// The source of `piece`; the bundle for a name that is no piece.
    pub fn source(&self, piece: &str) -> &Source {
        self.pieces
            .iter()
            .find(|(name, _)| *name == piece)
            .map_or(&Source::Bundled, |(_, s)| s)
    }
}

/// What each piece serves: `active` is the key of the update the app would serve with no
/// switch file (none: its bundle), `kept` the keys of the older verified updates it still
/// holds, newest first.
///
/// - A piece with no switch serves `active`, unless `refuse` names it: then the newest kept
///   update that is not refused, else the bundle.
/// - `bundled` serves the bundle.
/// - `last-good` serves the newest kept update that is not refused (never `active`, the one
///   being switched out), else the bundle.
/// - A piece the file switched in a way this build cannot read serves the bundle.
pub fn plan(switches: Option<&Switches>, active: Option<&str>, kept: &[&str]) -> Plan {
    let refused = |key: &str| switches.is_some_and(|s| s.refuse.contains(key));
    let last_good = kept
        .iter()
        .find(|key| !refused(key) && Some(**key) != active)
        .map(|key| Source::Update((*key).to_owned()));
    let refused_active = active.is_some_and(refused);
    let normal = match active {
        Some(key) if !refused(key) => Source::Update(key.to_owned()),
        Some(_) => last_good.clone().unwrap_or(Source::Bundled),
        None => Source::Bundled,
    };
    let pieces = PIECES
        .iter()
        .map(|(name, _)| {
            let source = match switches {
                Some(s) if s.unknown.iter().any(|unknown| unknown == name) => Source::Bundled,
                Some(s) => match s.pieces.get(*name).map(|switch| switch.serve) {
                    Some(Serve::Bundled) => Source::Bundled,
                    Some(Serve::LastGood) => last_good.clone().unwrap_or(Source::Bundled),
                    None => normal.clone(),
                },
                None => normal.clone(),
            };
            (*name, source)
        })
        .collect();
    Plan {
        pieces,
        refused_active,
    }
}

/// One read of a switch file as JSON in and JSON out, for a host on the other side of an
/// RPC or a C ABI (the Mac app asks its daemon; the iPhone app its Rust core).
///
/// `input`: `{"envelope": "<the file's text>" | null, "channel": "every-merge", "floor": 6,
/// "active": "<key>" | null, "kept": ["<key>", ...], "now": 1795340000,
/// "last": {the "switches" of the last reply} | absent}`. A null `envelope` (no file
/// published, or the read failed) and a refused file both plan with `last`, the switches the
/// host last took, so a blocked or forged read never switches a piece back in.
///
/// Reply: `{"taken": bool, "refusal": {"code", "message"} | null, "serial": n,
/// "switches": {...} | null, "pieces": {"agent-pane": {"output": "...", "update": "<key>" |
/// null, "serve": "live" | "bundled" | "last-good", "reason": "..."}}, "refused_active":
/// bool, "refuse": [...], "log": {one line for the host's log}}`. The host stores `serial`
/// as its next `floor` and `switches` as its next `last` only when `taken`.
pub fn evaluate(input: &Value) -> Value {
    evaluate_with(input, &trusted_keys())
}

/// [`evaluate`] against `keys` (the tests' own).
pub fn evaluate_with(input: &Value, keys: &[cmux_signed_envelope::Key]) -> Value {
    let channel = input
        .get("channel")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let floor = input.get("floor").and_then(Value::as_u64).unwrap_or(0);
    let active = input.get("active").and_then(Value::as_str);
    let kept: Vec<&str> = input
        .get("kept")
        .and_then(Value::as_array)
        .map(|keys| keys.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let now = input.get("now").and_then(Value::as_u64).unwrap_or(0);
    let last = input
        .get("last")
        .and_then(switches_from_json)
        .filter(|s| s.channel == channel);
    let (taken, refusal) = match input.get("envelope").and_then(Value::as_str) {
        None => (None, None),
        Some(text) => match open(text.as_bytes(), keys, channel, floor) {
            Ok(switches) => (Some(switches), None),
            Err(refusal) => (None, Some(refusal)),
        },
    };
    let is_taken = taken.is_some();
    let switches = taken.or(last);
    let plan = plan(switches.as_ref(), active, &kept);
    let mut pieces = serde_json::Map::new();
    for ((name, output), (_, source)) in PIECES.iter().zip(&plan.pieces) {
        let switch = switches.as_ref().and_then(|s| s.pieces.get(*name));
        let unknown = switches
            .as_ref()
            .is_some_and(|s| s.unknown.iter().any(|u| u == name));
        let serve = match switch.map(|s| s.serve) {
            Some(Serve::Bundled) => "bundled",
            Some(Serve::LastGood) => "last-good",
            None if unknown => "bundled",
            None => "live",
        };
        pieces.insert(
            (*name).to_owned(),
            json!({"output": output, "update": source.json(), "serve": serve,
                   "reason": switch.map(|s| s.reason.as_str()).unwrap_or_default()}),
        );
    }
    let serial = switches.as_ref().map_or(floor, |s| s.serial.max(floor));
    let refusal_json = refusal.as_ref().map_or(
        Value::Null,
        |r| json!({"code": r.code(), "message": r.to_string()}),
    );
    let switched: Vec<String> = pieces
        .iter()
        .filter(|(_, piece)| piece["serve"] != "live")
        .map(|(name, piece)| format!("{name}={}", piece["serve"].as_str().unwrap_or_default()))
        .collect();
    let log = json!({
        "at": now, "event": "web-pieces", "channel": channel,
        "verdict": match (&refusal, is_taken) {
            (Some(refusal), _) => refusal.code(),
            (None, true) => "taken",
            (None, false) => "no_file",
        },
        "serial": serial, "floor": floor, "active": active,
        "switched": switched, "refused_active": plan.refused_active,
    });
    json!({
        "taken": is_taken, "refusal": refusal_json, "serial": serial,
        "switches": switches.as_ref().map_or(Value::Null, switches_json),
        "pieces": pieces, "refused_active": plan.refused_active,
        "refuse": switches.as_ref().map_or_else(Vec::new, |s| s.refuse.iter().cloned().collect()),
        "log": log,
    })
}

/// A verified file's switches as the JSON a host keeps between reads (`last`).
fn switches_json(switches: &Switches) -> Value {
    let pieces: serde_json::Map<String, Value> = switches
        .pieces
        .iter()
        .map(|(name, switch)| {
            let serve = match switch.serve {
                Serve::Bundled => "bundled",
                Serve::LastGood => "last-good",
            };
            (
                name.clone(),
                json!({"serve": serve, "reason": switch.reason}),
            )
        })
        .collect();
    json!({"channel": switches.channel, "serial": switches.serial,
           "published_at": switches.published_at, "pieces": pieces,
           "refuse": switches.refuse.iter().collect::<Vec<_>>(), "unknown": switches.unknown})
}

/// The switches a host kept ([`switches_json`]). The host's own file, read back: it was
/// verified when it was taken.
fn switches_from_json(value: &Value) -> Option<Switches> {
    let pieces = value
        .get("pieces")?
        .as_object()?
        .iter()
        .filter_map(|(name, switch)| {
            Some((
                name.clone(),
                serde_json::from_value::<Switch>(switch.clone()).ok()?,
            ))
        })
        .collect();
    let strings = |field: &str| -> Vec<String> {
        value
            .get(field)
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default()
    };
    Some(Switches {
        channel: value.get("channel")?.as_str()?.to_owned(),
        serial: value.get("serial")?.as_u64()?,
        published_at: value
            .get("published_at")
            .and_then(Value::as_u64)
            .unwrap_or(0),
        pieces,
        refuse: strings("refuse")
            .into_iter()
            .filter(|key| is_key(key))
            .collect(),
        unknown: strings("unknown"),
    })
}

#[cfg(test)]
mod tests;
