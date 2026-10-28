//! The generated `terminal-io` params decode every request line exactly as the
//! hand-written `Command` variants did before p05-ipc-026 (frozen below):
//! the same value, or an error for the same line. Lines come from
//! spec/fixtures/server-generated/terminal-io.json and from 1,000 proptest
//! lines built from the schema's own fields. Both sides parse the way the
//! daemon does, through the `id` + flattened `cmd` request wrapper.
//!
//! Commands and fields the schema added after the freeze are added to the
//! frozen family by hand, as the hand-written variant would have declared
//! them: attach-streams-v1 `stream` on attach-surface and
//! snapshot-request, and cancel-stream; set-stream-priority.
//!
//! Fixture errors must match too, with two wording differences: a line that misses
//! several required fields may name another of them (the generated fields are
//! in schema name order), and an out-of-range size names the schema's `u64` or
//! `i64` where the frozen enum said `usize` or `isize`.

use std::collections::BTreeSet;

use ghostty_vt::{KeyAction, KeyInput, Mods, sys};
use proptest::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::super::cmd_terminal_io::ExpectAgent;
use super::super::terminal_history::RowMarkerPoint;
use super::super::terminal_snapshot::SnapshotHave;
use super::super::{Command, ProtocolKeyInput, Request};
use crate::SurfaceId;

// ---- The hand-written family, frozen at origin/perf/chrome-parity 188db478eea.

#[derive(Deserialize, Serialize)]
struct OldRequest {
    id: Option<Value>,
    #[serde(flatten)]
    cmd: OldTerminalIo,
}

fn default_renderer_capability_ttl_ms() -> u64 {
    30_000
}

#[derive(Deserialize, Serialize)]
struct OldSendParams {
    #[serde(default)]
    surface: Option<SurfaceId>,
    #[serde(default)]
    terminal_id: Option<String>,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    bytes: Option<String>,
    #[serde(default)]
    paste: bool,
    #[serde(default)]
    expect_foreground: Option<String>,
    #[serde(default)]
    expect_agent: Option<ExpectAgent>,
    #[serde(default)]
    submit: bool,
    #[serde(default)]
    flow: Option<u64>,
}

#[derive(Default, Deserialize, Serialize)]
struct OldSnapshotAttachParams {
    #[serde(default)]
    snapshot: Option<String>,
    #[serde(default)]
    snapshot_version: Option<u16>,
    #[serde(default)]
    viewer_backlog_bytes: Option<usize>,
    #[serde(default)]
    snapshot_local_history: bool,
    #[serde(default)]
    snapshot_images: bool,
}

#[derive(Deserialize, Serialize)]
struct OldSnapshotRequestParams {
    surface: SurfaceId,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    have: Option<SnapshotHave>,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    stream: Option<u16>,
}

#[derive(Deserialize, Serialize)]
struct OldTerminalHistoryParams {
    surface: SurfaceId,
    #[serde(default)]
    before: Option<u64>,
    marker_epoch: u64,
    #[serde(default)]
    max_bytes: Option<usize>,
}

#[derive(Deserialize, Serialize)]
struct OldTerminalReadRangeParams {
    surface: SurfaceId,
    from: RowMarkerPoint,
    to: RowMarkerPoint,
    #[serde(default)]
    format: Option<String>,
    marker_epoch: u64,
    #[serde(default)]
    max_bytes: Option<usize>,
}

#[allow(clippy::enum_variant_names)]
#[derive(Deserialize, Serialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
enum OldTerminalIo {
    /// Durable ordered terminal mutations after `terminal_revision`.
    TerminalEvents {
        #[serde(default)]
        after_revision: u64,
    },
    /// `send`: write input to a terminal.
    Send(OldSendParams),
    ReadScreen {
        surface: SurfaceId,
    },
    ClearHistory {
        surface: SurfaceId,
        /// Structured key input encoded using the authoritative terminal
        /// modes when the surface is in the alternate screen.
        #[serde(default)]
        fallback_key: Option<ProtocolKeyInput>,
    },
    ReadScrollback {
        surface: SurfaceId,
        start: u32,
        count: u32,
    },
    WaitFor {
        surface: SurfaceId,
        pattern: String,
        #[serde(alias = "timeout_ms")]
        timeout_ms: u64,
    },
    SendKey {
        surface: SurfaceId,
        keys: Vec<String>,
    },
    Copy {
        surface: SurfaceId,
        mode: String,
    },
    /// One-shot VT replay of the surface's current state (base64).
    VtState {
        surface: SurfaceId,
    },
    /// Scroll a surface's viewport by a row delta (negative is up).
    ScrollSurface {
        surface: SurfaceId,
        delta: isize,
    },
    /// Mint a one-use direct renderer credential without exposing the
    /// daemon's durable owner capability.
    MintTerminalRenderer {
        surface: SurfaceId,
        #[serde(default = "default_renderer_capability_ttl_ms")]
        ttl_ms: u64,
    },
    GetCellPixels,
    /// Mint a renderer credential from the stable public terminal identity.
    /// Remote clients must not depend on this daemon generation's local numeric surface handle.
    MintTerminalRendererByTerminal {
        terminal: String,
        #[serde(default = "default_renderer_capability_ttl_ms")]
        ttl_ms: u64,
    },
    SetCellPixels {
        #[serde(alias = "width_px")]
        width_px: u16,
        #[serde(alias = "height_px")]
        height_px: u16,
    },
    /// Stream mux events on this connection.
    Subscribe {
        #[serde(default)]
        tree_events: Option<String>,
        #[serde(default)]
        surface: Option<SurfaceId>,
    },
    /// Stream a surface: vt-state event followed by live output events.
    AttachSurface {
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        expected_generation: Option<String>,
        #[serde(default)]
        expected_terminal_id: Option<String>,
        #[serde(default)]
        mode: Option<String>,
        /// Optional initial viewer size. Supplying this pair makes the attach
        /// stream a sizing participant immediately, before its first frame is rendered.
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
        #[serde(flatten)]
        snapshot: OldSnapshotAttachParams,
        #[serde(default)]
        stream: Option<u16>,
    },
    /// End one client-minted attach stream (attach-streams-v1).
    CancelStream {
        stream: u16,
    },
    /// Rank one client-minted attach stream.
    SetStreamPriority {
        stream: u16,
        priority: String,
    },
    PasteImage {
        surface: SurfaceId,
        terminal_id: String,
        lease: String,
        upload_id: String,
        op: String,
        mime: Option<String>,
        size: Option<usize>,
        offset: Option<usize>,
        data: Option<String>,
    },
    UrlOpen {
        terminal_id: String,
        url: String,
    },
    /// Private, connection-scoped guest-to-frontend OS browser opening.
    UrlOpenSubscribe {
        terminal_ids: Vec<String>,
    },
    UrlOpenClaim {
        request_id: String,
    },
    UrlOpenResult {
        request_id: String,
        opened: bool,
    },
    TerminalClipboardSubscribe {
        terminal_ids: Vec<String>,
    },
    TerminalClipboardReply {
        request_id: String,
        text: Option<String>,
    },
    /// One READY snapshot on the caller's snapshot attach (`terminal-snapshot-v1`).
    SnapshotRequest(OldSnapshotRequestParams),
    /// GHOSTSNP history pages above a row marker (`terminal.history`).
    TerminalHistory(OldTerminalHistoryParams),
    /// Text or VT of a row-marker range (`terminal.read_range`).
    TerminalReadRange(OldTerminalReadRangeParams),
}

// ---- Decoding a line both ways.

/// The generated command as the frozen enum serializes: `cmd`, its params,
/// and the request `id`. `None` for a command of another family.
fn generated(request: &Request) -> Option<Value> {
    let params = match &request.cmd {
        Command::TerminalEvents(p) => serde_json::to_value(p),
        Command::Send(p) => serde_json::to_value(p),
        Command::ReadScreen(p) => serde_json::to_value(p),
        Command::ClearHistory(p) => serde_json::to_value(p),
        Command::ReadScrollback(p) => serde_json::to_value(p),
        Command::WaitFor(p) => serde_json::to_value(p),
        Command::SendKey(p) => serde_json::to_value(p),
        Command::Copy(p) => serde_json::to_value(p),
        Command::VtState(p) => serde_json::to_value(p),
        Command::ScrollSurface(p) => serde_json::to_value(p),
        Command::MintTerminalRenderer(p) => serde_json::to_value(p),
        Command::GetCellPixels => Ok(json!({})),
        Command::MintTerminalRendererByTerminal(p) => serde_json::to_value(p),
        Command::SetCellPixels(p) => serde_json::to_value(p),
        Command::Subscribe(p) => serde_json::to_value(p),
        Command::AttachSurface(p) => serde_json::to_value(p),
        Command::CancelStream(p) => serde_json::to_value(p),
        Command::SetStreamPriority(p) => serde_json::to_value(p),
        Command::PasteImage(p) => serde_json::to_value(p),
        Command::UrlOpen(p) => serde_json::to_value(p),
        Command::UrlOpenSubscribe(p) => serde_json::to_value(p),
        Command::UrlOpenClaim(p) => serde_json::to_value(p),
        Command::UrlOpenResult(p) => serde_json::to_value(p),
        Command::TerminalClipboardSubscribe(p) => serde_json::to_value(p),
        Command::TerminalClipboardReply(p) => serde_json::to_value(p),
        Command::SnapshotRequest(p) => serde_json::to_value(p),
        Command::TerminalHistory(p) => serde_json::to_value(p),
        Command::TerminalReadRange(p) => serde_json::to_value(p),
        _ => return None,
    };
    let mut value = params.unwrap();
    value["cmd"] = json!(request.cmd.wire_name());
    value["id"] = request.id.clone().unwrap_or(Value::Null);
    Some(value)
}

fn frozen(request: &OldRequest) -> Value {
    let mut value = serde_json::to_value(&request.cmd).unwrap();
    value["id"] = request.id.clone().unwrap_or(Value::Null);
    value
}

/// Decodes `line` both ways; panics where they disagree. Returns the wire
/// name of a line both decode. With `exact_errors`, a refused line must be
/// refused with the same error (the fixture lines have one fault each; a
/// random line with several may have another reported first).
fn agree(line: &str, exact_errors: bool) -> Option<String> {
    let old = serde_json::from_str::<OldRequest>(line).map(|request| frozen(&request));
    let new = serde_json::from_str::<Request>(line).map(|request| {
        generated(&request).unwrap_or_else(|| panic!("{line}: decoded outside terminal-io"))
    });
    match (old, new) {
        (Ok(old), Ok(new)) => {
            assert_eq!(old, new, "{line}");
            Some(new["cmd"].as_str().unwrap().to_owned())
        }
        (Err(old), Err(new)) => {
            // The frozen enum held schema `uint64` and `int64` sizes as
            // `usize` and `isize`, so its out-of-range errors name those.
            let old = old.to_string().replace("expected usize", "expected u64");
            let old = old.replace("expected isize", "expected i64");
            let new = new.to_string();
            let both_missing = old.contains("missing field") && new.contains("missing field");
            assert!(
                !exact_errors || old == new || both_missing,
                "{line}: old error {old:?}, new error {new:?}"
            );
            None
        }
        (old, new) => panic!("{line}: old {:?}, generated {:?}", old.ok(), new.ok()),
    }
}

// ---- The schema's terminal-io commands and a value table per field type.

const SDK_SCHEMA: &str = include_str!("../../../../spec/sdk-schema.json");
const FIXTURE: &str = include_str!("../../../../spec/fixtures/server-generated/terminal-io.json");

/// Values a line may give one field: ones of its type, and edge values,
/// `null` and other types that one side or both may refuse.
struct Values {
    valid: Vec<Value>,
    odd: Vec<Value>,
}

struct SchemaCommand {
    wire: String,
    fields: Vec<(String, Values)>,
}

fn terminal_io_commands() -> Vec<SchemaCommand> {
    let sdk: Value = serde_json::from_str(SDK_SCHEMA).unwrap();
    let family = sdk["families"]["terminal-io"]["id"].as_u64().unwrap();
    let types = sdk["types"].as_object().unwrap();
    let mut commands: Vec<(u64, SchemaCommand)> = sdk["commands"]
        .as_object()
        .unwrap()
        .iter()
        .filter_map(|(wire, command)| {
            let id = command["method_id"].as_u64()?;
            (id >> 8 == family).then(|| {
                let fields = command["request"]["fields"]
                    .as_object()
                    .map(|fields| {
                        fields
                            .iter()
                            .map(|(name, field)| (name.clone(), values(&field["type"], types)))
                            .collect()
                    })
                    .unwrap_or_default();
                (id, SchemaCommand { wire: wire.clone(), fields })
            })
        })
        .collect();
    commands.sort_by_key(|(id, _)| *id);
    commands.into_iter().map(|(_, command)| command).collect()
}

/// A valid `TerminalKeyInput`, as a client encodes it.
fn key_input() -> Value {
    let input = KeyInput {
        key: sys::GHOSTTY_KEY_K,
        mods: Mods::SUPER,
        unshifted_codepoint: 'k' as u32,
        action: Some(KeyAction::Press),
        ..Default::default()
    };
    serde_json::to_value(ProtocolKeyInput::try_from(&input).unwrap()).unwrap()
}

fn values(expression: &Value, types: &Map<String, Value>) -> Values {
    let (valid, mut odd) = match expression["kind"].as_str().unwrap() {
        "scalar" => scalar_values(expression["name"].as_str().unwrap()),
        "alias" => return values(&expression["target"], types),
        "enum" => {
            (expression["values"].as_array().unwrap().clone(), vec![json!("not-a-value"), json!(1)])
        }
        "array" => {
            let items = values(&expression["items"], types);
            let some = Value::Array(items.valid.iter().take(2).cloned().collect());
            let mixed = json!([items.valid[0], items.odd[0]]);
            (vec![json!([]), some], vec![mixed, json!("x")])
        }
        "ref" => {
            let name = expression["name"].as_str().unwrap();
            let target = &types[name];
            if target["kind"] == "alias" {
                return values(target, types);
            }
            ref_values(name)
        }
        other => panic!("terminal-io field type kind {other} has no value table"),
    };
    odd.push(Value::Null);
    Values { valid, odd }
}

fn scalar_values(name: &str) -> (Vec<Value>, Vec<Value>) {
    match name {
        "string" => (
            vec![json!(""), json!("ghostsnp"), json!("bytes"), json!("gap"), json!("é\n\"")],
            vec![json!(7), json!(true), json!(["x"])],
        ),
        "boolean" => (vec![json!(true), json!(false)], vec![json!(0), json!("true")]),
        "uint16" => (
            vec![json!(0), json!(80), json!(u16::MAX)],
            vec![json!(65_536), json!(-1), json!(1.5), json!("1")],
        ),
        "uint32" => (
            vec![json!(0), json!(10), json!(u32::MAX)],
            vec![json!(4_294_967_296_u64), json!(-1), json!("1")],
        ),
        "uint64" => (
            vec![json!(0), json!(30_000), json!(u64::MAX)],
            vec![json!(-1), json!(2.5), json!("9")],
        ),
        "int64" => (
            vec![json!(0), json!(-5), json!(i64::MIN), json!(i64::MAX)],
            vec![json!(u64::MAX), json!(0.5), json!("1")],
        ),
        other => panic!("terminal-io scalar {other} has no value table"),
    }
}

fn ref_values(name: &str) -> (Vec<Value>, Vec<Value>) {
    match name {
        "SendExpectAgent" => (
            vec![json!({"session": "s-1"}), json!({}), json!({"session": null})],
            vec![json!({"session": 1}), json!({"other": true}), json!("s-1")],
        ),
        "SnapshotRequestHave" => (
            vec![json!({"generation": 1, "offset": 2, "snapshot_version": 3}), json!({})],
            vec![json!({"snapshot_version": 70_000}), json!({"offset": "x"}), json!([1])],
        ),
        "RowMarkerPoint" => (
            vec![json!({"row_marker": 5, "col": 2}), json!({"row_marker": 5, "col": 2, "x": 1})],
            vec![json!({"row_marker": 5}), json!({"row_marker": -1, "col": 2}), json!(5)],
        ),
        "TerminalKeyInput" => {
            let valid = key_input();
            let mut unknown = valid.clone();
            unknown["key"] = json!("future-key");
            let mut extra = valid.clone();
            extra["extra"] = json!(1);
            (vec![valid], vec![unknown, extra, json!({}), json!("k")])
        }
        other => panic!("terminal-io ref {other} has no value table"),
    }
}

/// One request line: command `pick`, and for each field (by its byte of
/// `choices`) one of its valid values most of the time, else nothing, an odd
/// value or `null`; plus an `id` and an unknown field when `extras` says so.
fn line(commands: &[SchemaCommand], pick: usize, choices: &[u8], extras: u8) -> String {
    let command = &commands[pick % commands.len()];
    let mut object = Map::new();
    if extras & 1 != 0 {
        object.insert("id".into(), json!(u64::from(extras)));
    }
    object.insert("cmd".into(), json!(command.wire));
    for (index, (name, values)) in command.fields.iter().enumerate() {
        let choice = usize::from(choices[index % choices.len()]);
        let value = match choice % 8 {
            0 => None,
            1 => values.odd.get(choice / 8 % values.odd.len()),
            _ => values.valid.get(choice / 8 % values.valid.len()),
        };
        if let Some(value) = value {
            object.insert(name.clone(), value.clone());
        }
    }
    if extras & 2 != 0 {
        object.insert("future_field".into(), json!({"nested": [1, 2]}));
    }
    Value::Object(object).to_string()
}

#[test]
fn server_generated_terminal_io_agrees_on_the_fixtures() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let mut lines: Vec<String> =
        fixture["requests"].as_array().unwrap().iter().map(Value::to_string).collect();
    lines.extend(
        fixture["lines"].as_array().unwrap().iter().map(|line| line.as_str().unwrap().to_owned()),
    );
    let decoded: BTreeSet<String> = lines.iter().filter_map(|line| agree(line, true)).collect();
    let family: BTreeSet<String> =
        terminal_io_commands().into_iter().map(|command| command.wire).collect();
    assert_eq!(decoded, family, "every terminal-io command has a fixture line that decodes");
}

/// Every schema field, given its first valid value, decodes on both sides:
/// the frozen enum and the schema name the same commands and fields.
#[test]
fn server_generated_terminal_io_covers_the_frozen_family() {
    for command in terminal_io_commands() {
        let mut object: Map<String, Value> = command
            .fields
            .iter()
            .map(|(name, values)| (name.clone(), values.valid[0].clone()))
            .collect();
        object.insert("cmd".into(), json!(command.wire));
        let line = Value::Object(object).to_string();
        assert!(serde_json::from_str::<OldRequest>(&line).is_ok(), "{line}");
        assert!(agree(&line, true).is_some(), "{line}");
    }
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 1_000,
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    #[test]
    fn server_generated_terminal_io_agrees_on_proptest_lines(
        pick in any::<usize>(),
        choices in prop::collection::vec(any::<u8>(), 1..12),
        extras in any::<u8>(),
    ) {
        thread_local! {
            static COMMANDS: Vec<SchemaCommand> = terminal_io_commands();
        }
        COMMANDS.with(|commands| {
            agree(&line(commands, pick, &choices, extras), false);
        });
    }
}
