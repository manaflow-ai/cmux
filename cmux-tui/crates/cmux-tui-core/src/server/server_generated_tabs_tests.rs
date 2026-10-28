//! The generated `tabs` params decode every request line
//! exactly as the hand-written `Command` variants did before that task (frozen
//! below): the same value, or an error for the same line. Lines come from
//! spec/fixtures/server-generated/tabs.json and from 1,000 proptest lines
//! built from the schema's own fields. Both sides parse the way the daemon
//! does, through the `id` + flattened `cmd` request wrapper.

use std::collections::{BTreeMap, BTreeSet};

use proptest::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::super::conversation_tabs_wire::{AgentSessionParams, ConversationTabSplitParams};
use super::super::split_respawn::SplitRespawnRequest;
use super::super::{Command, Request, TabRef};
use crate::{PaneId, ScreenId, SplitId, SurfaceId, WorkspaceId};

// ---- The hand-written family, frozen at origin/perf/chrome-parity f392517ab2d.

#[derive(Deserialize, Serialize)]
struct OldRequest {
    id: Option<Value>,
    #[serde(flatten)]
    cmd: OldTabs,
}

#[derive(Deserialize, Serialize)]
struct OldCreateSurfaceWithReceiptRequest {
    operation: String,
    origin: String,
    receipt: String,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    selectors: Option<crate::ResourceSelectors>,
    #[serde(default)]
    selector_fallbacks: Vec<crate::ResourceSelectors>,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    workspace: Option<WorkspaceId>,
    #[serde(default)]
    argv: Option<Vec<String>>,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    width: Option<f32>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

#[derive(Debug, Default, Deserialize, Serialize)]
struct OldMutationRequest {
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    mutation_id: Option<String>,
    #[serde(default)]
    expected_generation: Option<String>,
    #[serde(default, alias = "expected_terminal_revision")]
    expected_revision: Option<u64>,
}

#[derive(Deserialize, Serialize)]
struct OldNewConversationTabParams {
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    workspace: Option<WorkspaceId>,
    #[serde(default)]
    conversation: Option<String>,
    #[serde(default)]
    owner: Option<String>,
    #[serde(default)]
    agent_session: Option<AgentSessionParams>,
    #[serde(default)]
    page: Option<String>,
    #[serde(default)]
    route: Option<String>,
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    mutation_id: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    #[serde(default)]
    transaction: Option<String>,
    #[serde(default)]
    split: Option<ConversationTabSplitParams>,
}

fn old_required_nullable<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<String>, D::Error> {
    Option::deserialize(deserializer)
}

#[derive(Deserialize, Serialize)]
struct OldBindSessionParams {
    surface: SurfaceId,
    session: String,
    #[serde(deserialize_with = "old_required_nullable")]
    expected_session: Option<String>,
    #[serde(default)]
    harness: Option<String>,
}

const fn old_activate_by_default() -> bool {
    true
}

#[derive(Deserialize, Serialize)]
struct OldNewFrontendBrowserTabParams {
    url: String,
    engine: String,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    favicon_url: Option<String>,
    #[serde(default)]
    profile_id: Option<String>,
    #[serde(default)]
    owner: Option<String>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
    #[serde(default = "old_activate_by_default")]
    activate: bool,
    #[serde(default)]
    after: Option<SurfaceId>,
}

#[derive(Deserialize, Serialize)]
struct OldRestartParams {
    #[serde(alias = "tab")]
    surface: TabRef,
}

#[derive(Deserialize, Serialize)]
struct OldParkParams {
    #[serde(alias = "tabs")]
    surfaces: Vec<TabRef>,
}

#[derive(Deserialize, Serialize)]
struct OldSetHistoryParams {
    surface: SurfaceId,
    history: Value,
}

#[derive(Deserialize, Serialize)]
struct OldSurfaceParams {
    surface: SurfaceId,
}

#[derive(Deserialize, Serialize)]
struct OldNewRemoteParams {
    session_id: String,
    terminal_id: String,
    session_name: String,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

fn old_present_nullable<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

#[derive(Deserialize, Serialize)]
struct OldUpdateFrontendBrowserTabParams {
    surface: SurfaceId,
    #[serde(default)]
    url: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(
        default,
        deserialize_with = "old_present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    favicon_url: Option<Option<String>>,
    #[serde(
        default,
        deserialize_with = "old_present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    profile_id: Option<Option<String>>,
    #[serde(default)]
    owner: Option<String>,
}

#[derive(Deserialize, Serialize)]
struct OldUpdateRemoteParams {
    surface: SurfaceId,
    #[serde(
        default,
        deserialize_with = "old_present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    title: Option<Option<String>>,
    #[serde(default)]
    session_name: Option<String>,
    #[serde(
        default,
        deserialize_with = "old_present_nullable",
        skip_serializing_if = "Option::is_none"
    )]
    snapshot: Option<Option<String>>,
}

#[derive(Deserialize, Serialize)]
struct OldMoveTabToColumnParams {
    surface: SurfaceId,
    #[serde(default)]
    pane: Option<PaneId>,
    #[serde(default)]
    screen: Option<ScreenId>,
    #[serde(default)]
    after_column: Option<SplitId>,
    #[serde(default)]
    width: Option<f32>,
    #[serde(default)]
    dock: Option<crate::model::ColumnDock>,
    #[serde(default)]
    sticky: Option<Value>,
    #[serde(default)]
    respawn: Option<SplitRespawnRequest>,
    #[serde(default)]
    keep_focus: bool,
    #[serde(default)]
    transaction: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "cmd", rename_all = "kebab-case")]
enum OldTabs {
    UpdateFrontendBrowserTab(OldUpdateFrontendBrowserTabParams),
    UpdateRemoteTerminalTab(OldUpdateRemoteParams),
    MoveTabToColumn(OldMoveTabToColumnParams),
    CreateSurfaceWithReceipt(Box<OldCreateSurfaceWithReceiptRequest>),
    Notify {
        title: String,
        body: String,
        #[serde(default)]
        level: Option<String>,
        #[serde(default)]
        surface: Option<SurfaceId>,
        #[serde(default)]
        source: Option<String>,
    },
    NewTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        env: Option<BTreeMap<String, String>>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
        #[serde(default)]
        keep: bool,
        #[serde(default)]
        terminal_id: Option<String>,
        #[serde(default)]
        shell_args: Option<Vec<String>>,
    },
    NewConversationTab(OldNewConversationTabParams),
    BindConversationTabSession(OldBindSessionParams),
    NewFrontendBrowserTab(OldNewFrontendBrowserTabParams),
    RestartTab(OldRestartParams),
    ParkTabs(OldParkParams),
    SetFrontendBrowserHistory(OldSetHistoryParams),
    GetFrontendBrowserHistory(OldSurfaceParams),
    NewRemoteTerminalTab(OldNewRemoteParams),
    RemoteTerminalSnapshot(OldSurfaceParams),
    NewBrowserTab {
        url: String,
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
    },
    MoveTab {
        surface: SurfaceId,
        pane: PaneId,
        index: usize,
        #[serde(default)]
        transaction: Option<String>,
    },
    AckTabNotifications {
        surface: SurfaceId,
    },
    ListNotifications {
        #[serde(default)]
        limit: Option<usize>,
    },
    SetTabPinned {
        surface: SurfaceId,
        pinned: bool,
    },
    MoveTabToWorkspace {
        surface: SurfaceId,
        #[serde(default)]
        workspace: Option<WorkspaceId>,
        #[serde(default)]
        transaction: Option<String>,
    },
    MoveTabToSplit {
        surface: SurfaceId,
        pane: PaneId,
        edge: String,
        #[serde(default)]
        ratio: Option<f32>,
        #[serde(default)]
        respawn: Option<SplitRespawnRequest>,
        #[serde(default)]
        keep_focus: bool,
        #[serde(default)]
        transaction: Option<String>,
    },
    MoveTabToNewWorkspace {
        surface: SurfaceId,
        #[serde(default)]
        group: Option<String>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        transaction: Option<String>,
    },
    CloseSurface {
        surface: SurfaceId,
    },
    CloseTabs {
        surfaces: Vec<TabRef>,
        #[serde(default)]
        end_terminals: bool,
        #[serde(default)]
        transaction: Option<String>,
        #[serde(default)]
        reason: Option<crate::mux::CloseReason>,
        #[serde(flatten)]
        mutation: OldMutationRequest,
    },
    RenameSurface {
        surface: SurfaceId,
        name: String,
    },
    SelectTab {
        #[serde(default)]
        pane: Option<PaneId>,
        #[serde(default)]
        index: Option<usize>,
        #[serde(default)]
        delta: Option<isize>,
    },
}

// ---- Decoding a line both ways.

fn generated(request: &Request) -> Option<Value> {
    let params = match &request.cmd {
        Command::CreateSurfaceWithReceipt(p) => serde_json::to_value(p),
        Command::Notify(p) => serde_json::to_value(p),
        Command::NewTab(p) => serde_json::to_value(p),
        Command::NewBrowserTab(p) => serde_json::to_value(p),
        Command::MoveTab(p) => serde_json::to_value(p),
        Command::CloseSurface(p) => serde_json::to_value(p),
        Command::RenameSurface(p) => serde_json::to_value(p),
        Command::SelectTab(p) => serde_json::to_value(p),
        Command::MoveTabToWorkspace(p) => serde_json::to_value(p),
        Command::NewConversationTab(p) => serde_json::to_value(p),
        Command::BindConversationTabSession(p) => serde_json::to_value(p),
        Command::NewFrontendBrowserTab(p) => serde_json::to_value(p),
        Command::UpdateFrontendBrowserTab(p) => serde_json::to_value(p),
        Command::RestartTab(p) => serde_json::to_value(p),
        Command::ParkTabs(p) => serde_json::to_value(p),
        Command::SetFrontendBrowserHistory(p) => serde_json::to_value(p),
        Command::GetFrontendBrowserHistory(p) => serde_json::to_value(p),
        Command::CloseTabs(p) => serde_json::to_value(p),
        Command::AckTabNotifications(p) => serde_json::to_value(p),
        Command::ListNotifications(p) => serde_json::to_value(p),
        Command::SetTabPinned(p) => serde_json::to_value(p),
        Command::MoveTabToSplit(p) => serde_json::to_value(p),
        Command::MoveTabToColumn(p) => serde_json::to_value(p),
        Command::MoveTabToNewWorkspace(p) => serde_json::to_value(p),
        Command::NewRemoteTerminalTab(p) => serde_json::to_value(p),
        Command::UpdateRemoteTerminalTab(p) => serde_json::to_value(p),
        Command::RemoteTerminalSnapshot(p) => serde_json::to_value(p),
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

/// Decodes `line` with the frozen enum and the generated params: both must
/// give the same value, or both an error. With `exact_errors` the errors must
/// say the same, apart from which of several missing fields they name (the
/// generated fields are in schema name order) and the schema's `u64`/`i64`
/// where the frozen enum held a `usize`/`isize`.
fn agree(line: &str, exact_errors: bool) -> Option<String> {
    let old = serde_json::from_str::<OldRequest>(line).map(|request| frozen(&request));
    let new = serde_json::from_str::<Request>(line).map(|request| {
        generated(&request).unwrap_or_else(|| panic!("{line}: decoded outside tabs"))
    });
    match (old, new) {
        (Ok(old), Ok(new)) => {
            assert_eq!(old, new, "{line}");
            Some(new["cmd"].as_str().unwrap().to_owned())
        }
        (Err(old), Err(new)) => {
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

// ---- The schema's tabs commands and a value table per field type.

const SDK_SCHEMA: &str = include_str!("../../../../spec/sdk-schema.json");
const FIXTURE: &str = include_str!("../../../../spec/fixtures/server-generated/tabs.json");
const FAMILIES: &str = include_str!("../../../cmux-ipc/server-families.json");

struct Values {
    valid: Vec<Value>,
    odd: Vec<Value>,
}

struct SchemaCommand {
    wire: String,
    fields: Vec<(String, Values)>,
}

/// Every tabs command with its schema fields, plus the refused fields
/// server-families.json gives it, in method id order.
fn tabs_commands() -> Vec<SchemaCommand> {
    let sdk: Value = serde_json::from_str(SDK_SCHEMA).unwrap();
    let families: Value = serde_json::from_str(FAMILIES).unwrap();
    let family = sdk["families"]["tabs"]["id"].as_u64().unwrap();
    let types = sdk["types"].as_object().unwrap();
    let mut commands: Vec<(u64, SchemaCommand)> = sdk["commands"]
        .as_object()
        .unwrap()
        .iter()
        .filter_map(|(wire, command)| {
            let id = command["method_id"].as_u64()?;
            (id >> 8 == family).then(|| {
                let mut fields: Vec<(String, Values)> = command["request"]["fields"]
                    .as_object()
                    .map(|fields| {
                        fields
                            .iter()
                            .map(|(name, field)| (name.clone(), values(&field["type"], types)))
                            .collect()
                    })
                    .unwrap_or_default();
                if let Some(refused) = families["refused_fields"][wire.as_str()].as_object() {
                    fields.extend(refused.keys().map(|name| (name.clone(), refused_values())));
                }
                (id, SchemaCommand { wire: wire.clone(), fields })
            })
        })
        .collect();
    commands.sort_by_key(|(id, _)| *id);
    commands.into_iter().map(|(_, command)| command).collect()
}

fn refused_values() -> Values {
    Values { valid: vec![json!({"edge": "left"}), json!(true)], odd: vec![Value::Null] }
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
        "map" => {
            let items = values(&expression["values"], types);
            let some = json!({"A": items.valid[0], "B": items.valid[1]});
            (vec![json!({}), some], vec![json!({"A": items.odd[0]}), json!(["A"])])
        }
        "ref" => {
            let name = expression["name"].as_str().unwrap();
            let target = &types[name];
            if matches!(target["kind"].as_str(), Some("alias" | "enum")) {
                return values(target, types);
            }
            ref_values(name)
        }
        other => panic!("tabs field type kind {other} has no value table"),
    };
    odd.push(Value::Null);
    Values { valid, odd }
}

fn scalar_values(name: &str) -> (Vec<Value>, Vec<Value>) {
    match name {
        "string" => (
            vec![json!(""), json!("tab_0123"), json!("webkit"), json!("é\n\"")],
            vec![json!(7), json!(true), json!(["x"])],
        ),
        "boolean" => (vec![json!(true), json!(false)], vec![json!(0), json!("true")]),
        "uint16" => (
            vec![json!(0), json!(80), json!(u16::MAX)],
            vec![json!(65_536), json!(-1), json!(1.5), json!("1")],
        ),
        "uint64" => {
            (vec![json!(0), json!(7), json!(u64::MAX)], vec![json!(-1), json!(2.5), json!("9")])
        }
        "int64" => (
            vec![json!(0), json!(-5), json!(i64::MIN), json!(i64::MAX)],
            vec![json!(u64::MAX), json!(0.5), json!("1")],
        ),
        "float32" => (vec![json!(0.5), json!(0), json!(-1.25)], vec![json!("0.5"), json!(true)]),
        other => panic!("tabs scalar {other} has no value table"),
    }
}

fn ref_values(name: &str) -> (Vec<Value>, Vec<Value>) {
    match name {
        "TabRef" => (vec![json!(3), json!("tab_0123")], vec![json!(-1), json!(true), json!({})]),
        "JsonValue" => {
            (vec![json!({"entries": [1]}), json!({}), json!([1, "x"]), json!(4)], vec![json!(true)])
        }
        "ResourceSelectors" => (
            vec![json!({"workspace": "ws_1", "pane": "pane_2"}), json!({})],
            vec![json!({"workspace": 1}), json!({"bogus": "x"}), json!("ws_1")],
        ),
        "AgentSessionSource" => (
            vec![
                json!({"host": "install:a", "session": "s", "harness": "claude", "host_name": "m"}),
                json!({"host": "chief:0123abcd"}),
            ],
            vec![json!({"session": "s"}), json!({"host": "h", "extra": 1}), json!("h")],
        ),
        "ConversationTabSplit" => (
            vec![json!({"direction": "right"}), json!({"direction": "up", "pane_id": "pane_1"})],
            vec![json!({}), json!({"direction": "left", "x": 1}), json!("right")],
        ),
        "SplitRespawn" => (
            vec![
                json!({"kind": "terminal", "cwd": "/tmp", "env": {"A": "b"}, "shell_args": ["-l"]}),
                json!({"kind": "browser", "url": "https://a.test", "engine": "cef"}),
            ],
            vec![json!({"cwd": "/tmp"}), json!({"kind": 1}), json!("terminal")],
        ),
        "ColumnPin" => (
            vec![
                json!({"edge": "left", "mode": "docked"}),
                json!({"edge": "right", "mode": "overlay", "role": "agent_chat"}),
            ],
            vec![json!({"edge": "up", "mode": "docked"}), json!({"edge": "left"}), json!(1)],
        ),
        other => panic!("tabs ref {other} has no value table"),
    }
}

fn line(commands: &[SchemaCommand], pick: usize, choices: &[u8], extras: u8) -> String {
    let command = &commands[pick % commands.len()];
    let mut object = Map::new();
    if extras & 1 != 0 {
        object.insert("id".into(), json!(u64::from(extras)));
    }
    object.insert("cmd".into(), json!(command.wire));
    for (index, (name, values)) in command.fields.iter().enumerate() {
        // Mostly valid lines, so most decode and the values are compared:
        // a field is absent 4 times in 16 and odd once.
        let choice = usize::from(choices[index % choices.len()]);
        let value = match choice % 16 {
            0..=3 => None,
            4 => values.odd.get(choice / 16 % values.odd.len()),
            _ => values.valid.get(choice / 16 % values.valid.len()),
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
fn server_generated_tabs_agrees_on_the_fixtures() {
    let fixture: Value = serde_json::from_str(FIXTURE).unwrap();
    let mut lines: Vec<String> =
        fixture["requests"].as_array().unwrap().iter().map(Value::to_string).collect();
    lines.extend(
        fixture["lines"].as_array().unwrap().iter().map(|line| line.as_str().unwrap().to_owned()),
    );
    let decoded: BTreeSet<String> = lines.iter().filter_map(|line| agree(line, true)).collect();
    let family: BTreeSet<String> =
        tabs_commands().into_iter().map(|command| command.wire).collect();
    assert_eq!(decoded, family, "every tabs command has a fixture line that decodes");
}

/// Every schema field, given its first valid value, decodes on both sides:
/// the frozen enum and the schema name the same commands and fields.
#[test]
fn server_generated_tabs_covers_the_frozen_family() {
    for command in tabs_commands() {
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

/// `null` and absent stay apart where the handler tells them apart:
/// `profile_id: null` clears the profile, an absent one leaves it.
#[test]
fn server_generated_tabs_keeps_null_apart_from_absent() {
    let decode = |line: Value| match serde_json::from_value::<Request>(line).unwrap().cmd {
        Command::UpdateFrontendBrowserTab(params) => (params.favicon_url, params.profile_id),
        _ => panic!("not update-frontend-browser-tab"),
    };
    let absent = decode(json!({"cmd": "update-frontend-browser-tab", "surface": 1}));
    assert_eq!(absent, (None, None));
    let cleared = decode(json!({
        "cmd": "update-frontend-browser-tab", "surface": 1, "favicon_url": null, "profile_id": null,
    }));
    assert_eq!(cleared, (Some(None), Some(None)));
    let missing_history = serde_json::from_value::<Request>(
        json!({"cmd": "set-frontend-browser-history", "surface": 1}),
    );
    assert!(missing_history.is_err(), "history is required even though it may be null");
}

/// Parse, dispatch and the pending queue move every `Command` by value, so
/// the generated variants keep it as small as the hand-written enum was
/// (376 bytes on 64-bit, with `create-surface-with-receipt` boxed). A family
/// migration that grows it names its large command in server-families.json
/// `boxed`. clippy's `large_enum_variant` cannot see the macro's variants.
#[test]
fn server_generated_tabs_keeps_command_small() {
    assert!(
        size_of::<Command>() <= 376,
        "Command is {} bytes; box the large variant in server-families.json `boxed`",
        size_of::<Command>()
    );
    assert!(size_of::<Request>() <= 408, "Request is {} bytes", size_of::<Request>());
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: 1_000,
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    #[test]
    fn server_generated_tabs_agrees_on_proptest_lines(
        pick in any::<usize>(),
        choices in prop::collection::vec(any::<u8>(), 1..16),
        extras in any::<u8>(),
    ) {
        thread_local! {
            static COMMANDS: Vec<SchemaCommand> = tabs_commands();
        }
        COMMANDS.with(|commands| {
            agree(&line(commands, pick, &choices, extras), false);
        });
    }
}
