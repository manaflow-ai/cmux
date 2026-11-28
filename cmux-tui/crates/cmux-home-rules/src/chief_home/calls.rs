//! The `chief_home` ops past home resolution: records, archived and cloud Chiefs, the app acpmux move,
//! the directory, the hosted Chief, adoption and the old-Chief migration.

use super::{acpmux, adoption, directory, hosted, migration, records};
use crate::ops::{OpError, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Deserialize)]
struct Payload {
    #[serde(default)]
    value: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArchivedRequest {
    #[serde(flatten)]
    archived: records::Archived,
    #[serde(default)]
    rows: Vec<records::Row>,
    #[serde(default)]
    than: String,
    #[serde(default)]
    chief: Option<String>,
    #[serde(default)]
    participants: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CloudChiefsRequest {
    #[serde(flatten)]
    chiefs: records::CloudChiefs,
    #[serde(default)]
    choice: Option<String>,
    #[serde(default)]
    conversation: Option<String>,
}

#[derive(Deserialize)]
struct RootRequest {
    #[serde(default)]
    root: String,
}

#[derive(Deserialize)]
struct TextRequest {
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MarkRequest {
    #[serde(default)]
    pid: i32,
    #[serde(default)]
    app_home: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OnAppRequest {
    #[serde(default, rename = "hostPID")]
    host_pid: Option<i32>,
    #[serde(default, rename = "markedPID")]
    marked_pid: Option<i32>,
    #[serde(default)]
    marked_home: Option<String>,
    #[serde(default)]
    own_home: String,
}

#[derive(Deserialize)]
struct IdleRequest {
    #[serde(default)]
    census: Option<acpmux::Census>,
}

#[derive(Deserialize)]
struct LinkRequest {
    #[serde(default)]
    link: String,
    #[serde(default)]
    pid: i32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParentsRequest {
    #[serde(default)]
    home_root: String,
    #[serde(default)]
    chief_root: String,
    #[serde(default)]
    dev_build: bool,
    #[serde(default)]
    root: String,
}

#[derive(Deserialize)]
struct ListingsRequest {
    #[serde(default)]
    listings: Vec<directory::Listing>,
}

#[derive(Deserialize)]
struct SessionRequest {
    #[serde(default)]
    session: String,
    #[serde(default)]
    chief: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CodeRequest {
    #[serde(default)]
    owner_code: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WiringRequest {
    #[serde(default)]
    debug_build: bool,
    #[serde(default)]
    environment: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MemoryStepRequest {
    #[serde(default)]
    memory_done: bool,
    #[serde(default)]
    memory_exists: bool,
    #[serde(default)]
    tool_bundled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AdoptionRecordRequest {
    #[serde(default)]
    by: String,
    #[serde(default)]
    now: f64,
    #[serde(default)]
    backup: Option<String>,
    #[serde(default)]
    raw: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NamesRequest {
    #[serde(default)]
    name: String,
    #[serde(default)]
    names: Vec<String>,
    #[serde(default)]
    databases: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OldChiefsRequest {
    #[serde(default)]
    user_home: String,
    #[serde(default)]
    application_support: String,
    #[serde(default)]
    tags: Vec<String>,
    #[serde(default)]
    existing: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RunStepRequest {
    #[serde(default)]
    isolated: bool,
    #[serde(default)]
    record_exists: bool,
    #[serde(default)]
    blocking: Vec<String>,
}

/// What `ChiefConversationOwner.brainsValue` resolved on the Mac (the brain
/// host, the bundle `bin`, the login PATH, acpmux, the process environment).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BrainsRequest {
    #[serde(default)]
    executable: String,
    #[serde(default)]
    home: String,
    #[serde(default)]
    user_name: String,
    #[serde(default)]
    chief_title: String,
    #[serde(default)]
    bin_dir: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    acpmux_bin: Option<String>,
    #[serde(default)]
    bundled_cli: Option<String>,
    #[serde(default)]
    harness: Option<String>,
}

/// `CMUX_TUI_CHIEF_BRAINS` (cmux-tui-core chief_brains.rs): the brain
/// executable, the home and the `app` facts, keys sorted. An empty login
/// PATH or harness is left out; `bundled_cli` only rides with acpmux.
fn brains_value(request: BrainsRequest) -> String {
    let mut app = BTreeMap::new();
    if let Some(acpmux) = request.acpmux_bin {
        app.insert("acpmux_bin", acpmux);
        if let Some(cli) = request.bundled_cli {
            app.insert("bundled_cli", cli);
        }
    }
    if let Some(bin) = request.bin_dir {
        app.insert("bin_dir", bin);
    }
    app.insert("chief_title", request.chief_title);
    if let Some(harness) = request.harness.filter(|harness| !harness.is_empty()) {
        app.insert("harness", harness);
    }
    if let Some(path) = request.path.filter(|path| !path.is_empty()) {
        app.insert("path", path);
    }
    app.insert("user_name", request.user_name);
    json!({ "app": app, "executable": request.executable, "home": request.home }).to_string()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SourcesRequest {
    #[serde(default)]
    sources: Vec<migration::Source>,
    #[serde(default)]
    utc_offset_seconds: i64,
    #[serde(default)]
    unlogged_offsets: Vec<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HasMemoryRequest {
    #[serde(default)]
    database_exists: bool,
    #[serde(default)]
    main_names: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HostStateRequest {
    #[serde(default)]
    conversation: String,
    #[serde(default)]
    logged_seq: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MigrationRecordRequest {
    #[serde(default)]
    status: String,
    #[serde(default)]
    now: f64,
    #[serde(default)]
    olds: Vec<migration::Old>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LogLineRequest {
    #[serde(default)]
    i: i64,
    #[serde(default)]
    kind: String,
    #[serde(default)]
    text: String,
    #[serde(default)]
    date: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocalDateRequest {
    #[serde(default)]
    text: String,
    #[serde(default)]
    utc_offset_seconds: i64,
}

#[derive(Deserialize)]
struct FilesRequest {
    #[serde(default)]
    files: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CursorRequest {
    #[serde(default)]
    state: Option<BTreeMap<String, String>>,
    #[serde(default)]
    host_json: Option<String>,
}

#[derive(Deserialize)]
struct ConversationsRequest {
    #[serde(default)]
    conversations: Vec<migration::Conversation>,
}

#[derive(Deserialize)]
struct NameRequest {
    #[serde(default)]
    name: String,
}

pub(super) fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "record_list" => {
            let request: Payload = parse(request)?;
            Ok(json!({ "chiefs": records::list(&request.value) }))
        }
        "archived_ids" => {
            let request: Payload = parse(request)?;
            Ok(json!({ "ids": records::archived_ids(&request.value) }))
        }
        "archived_visible" => {
            let request: ArchivedRequest = parse(request)?;
            let ids: Vec<&str> =
                request.archived.visible(&request.rows).iter().map(|row| row.id.as_str()).collect();
            Ok(json!({ "visible": ids }))
        }
        "archived_other_chiefs" => {
            let request: ArchivedRequest = parse(request)?;
            Ok(json!({ "count": request.archived.other_chiefs(&request.than, &request.rows) }))
        }
        "archived_hidden" => {
            let request: ArchivedRequest = parse(request)?;
            Ok(json!({ "hidden": request.archived.hidden(&request.rows) }))
        }
        "archived_openable" => {
            let request: ArchivedRequest = parse(request)?;
            let openable = request.archived.openable(
                request.chief.as_deref(),
                &request.rows,
                &request.participants,
            );
            Ok(json!({ "openable": openable }))
        }
        "archived_hides" => {
            let request: ArchivedRequest = parse(request)?;
            Ok(json!({ "hides": request.archived.hides(&request.participants) }))
        }
        "cloud_parse" => {
            let request: Payload = parse(request)?;
            Ok(json!({ "chief": records::parse_cloud_chief(&request.value) }))
        }
        "cloud_choice" => {
            let request: CloudChiefsRequest = parse(request)?;
            Ok(json!({ "choice": records::choice(request.choice.as_deref()) }))
        }
        "cloud_chiefs" => {
            let request: CloudChiefsRequest = parse(request)?;
            let chiefs = &request.chiefs;
            let conversation = request.conversation.as_deref().unwrap_or_default();
            let choice = records::choice(request.choice.as_deref());
            Ok(json!({
                "shown": chiefs.shown(choice),
                "chiefFor": request.conversation.as_ref().and_then(|c| chiefs.chief_for(c)),
                "canSwitch": chiefs.can_switch(),
                "otherHost": chiefs.other_host(conversation),
            }))
        }
        "acpmux_plan" => {
            let request: acpmux::MoveInputs = parse(request)?;
            reply(&acpmux::plan(&request))
        }
        "acpmux_mark_file" => {
            let request: RootRequest = parse(request)?;
            Ok(json!({ "path": acpmux::mark_file(&request.root) }))
        }
        "acpmux_read_mark" => {
            let request: TextRequest = parse(request)?;
            reply(&acpmux::read_mark(&request.text))
        }
        "acpmux_mark_text" => {
            let request: MarkRequest = parse(request)?;
            Ok(json!({ "text": acpmux::mark_text(request.pid, &request.app_home) }))
        }
        "acpmux_on_app" => {
            let r: OnAppRequest = parse(request)?;
            Ok(
                json!({ "onAppAcpmux": acpmux::on_app_acpmux(r.host_pid, r.marked_pid, r.marked_home.as_deref(), &r.own_home) }),
            )
        }
        "acpmux_idle" => {
            let request: IdleRequest = parse(request)?;
            Ok(json!({ "idle": acpmux::idle(request.census.as_ref()) }))
        }
        "app_links" => {
            let request: RootRequest = parse(request)?;
            reply(&acpmux::links(&request.root))
        }
        "app_temporary_link" => {
            let request: LinkRequest = parse(request)?;
            Ok(json!({ "path": acpmux::temporary_link(&request.link, request.pid) }))
        }
        "directory_home_parents" => {
            let request: ParentsRequest = parse(request)?;
            Ok(
                json!({ "parents": directory::home_parents(&request.home_root, &request.chief_root) }),
            )
        }
        "directory_admits" => {
            let request: ParentsRequest = parse(request)?;
            Ok(
                json!({ "admits": directory::admits(&request.home_root, request.dev_build, &request.root) }),
            )
        }
        "directory_homes" => {
            let request: ListingsRequest = parse(request)?;
            Ok(json!({ "homes": directory::homes(&request.listings) }))
        }
        "directory_owned" => {
            let request: directory::OwnedInputs = parse(request)?;
            Ok(json!({ "owned": directory::owned(&request) }))
        }
        "ledger_keys" => {
            let request: SessionRequest = parse(request)?;
            reply(&hosted::ledger_keys(&request.session, &request.chief))
        }
        "ledger_is_refusal" => {
            let request: CodeRequest = parse(request)?;
            Ok(json!({ "refusal": hosted::is_refusal(request.owner_code.as_deref()) }))
        }
        "ledger_host" => {
            let request: SessionRequest = parse(request)?;
            Ok(
                json!({ "host": hosted::host(&request.session), "maxFailures": hosted::MAX_FAILURES }),
            )
        }
        "hosted_wiring_copies" => {
            let request: WiringRequest = parse(request)?;
            Ok(
                json!({ "copies": hosted::wiring_copies(request.debug_build, &request.environment) }),
            )
        }
        "hosted_start" => {
            let request: hosted::StartInputs = parse(request)?;
            reply(&hosted::start(&request))
        }
        "hosted_memory_step" => {
            let r: MemoryStepRequest = parse(request)?;
            Ok(
                json!({ "step": hosted::memory_step(r.memory_done, r.memory_exists, r.tool_bundled) }),
            )
        }
        "hosted_brain" => {
            let request: hosted::BrainInputs = parse(request)?;
            reply(&hosted::brain(&request))
        }
        "hosted_failure" => {
            let request: hosted::FailureInputs = parse(request)?;
            reply(&hosted::failure(&request))
        }
        "adoption_plan" => {
            let request: adoption::PlanInputs = parse(request)?;
            reply(&adoption::plan(&request))
        }
        "adoption_record" => {
            let r: AdoptionRecordRequest = parse(request)?;
            Ok(json!({ "json": adoption::record(&r.by, r.now, r.backup.as_deref(), &r.raw) }))
        }
        "adoption_is_sidecar" => {
            let request: NamesRequest = parse(request)?;
            Ok(json!({ "sidecar": adoption::is_sidecar(&request.name, &request.databases) }))
        }
        "adoption_raw_files" => {
            let request: NamesRequest = parse(request)?;
            Ok(json!({ "files": adoption::raw_files(&request.name, &request.names) }))
        }
        "migration_session_component" => {
            let request: SessionRequest = parse(request)?;
            Ok(json!({ "component": migration::session_component(&request.session) }))
        }
        "migration_old_chiefs" => {
            let r: OldChiefsRequest = parse(request)?;
            Ok(
                json!({ "olds": migration::old_chiefs(&r.user_home, &r.application_support, &r.tags, &r.existing) }),
            )
        }
        "migration_run_step" => {
            let r: RunStepRequest = parse(request)?;
            Ok(
                json!({ "step": migration::run_step(r.isolated, r.record_exists, &r.blocking), "blocked": r.blocking }),
            )
        }
        "migration_plan" => {
            let request: SourcesRequest = parse(request)?;
            let plan = migration::plan(&request.sources);
            let mut value =
                serde_json::to_value(&plan).map_err(|error| OpError::Invalid(error.to_string()))?;
            if let Some(fields) = value.as_object_mut() {
                fields.insert("imports".to_owned(), Value::Array(migration::imports(&plan)));
            }
            Ok(value)
        }
        "migration_memory" => {
            let request: SourcesRequest = parse(request)?;
            reply(&migration::memory_lines_dated(
                &request.sources,
                request.utc_offset_seconds,
                &request.unlogged_offsets,
            ))
        }
        "migration_has_memory" => {
            let request: HasMemoryRequest = parse(request)?;
            Ok(
                json!({ "hasMemory": migration::has_memory(request.database_exists, &request.main_names) }),
            )
        }
        "migration_host_state" => {
            let request: HostStateRequest = parse(request)?;
            Ok(json!({ "json": migration::host_state(&request.conversation, request.logged_seq) }))
        }
        "migration_record" => {
            let request: MigrationRecordRequest = parse(request)?;
            Ok(json!({ "json": migration::record(&request.status, request.now, &request.olds) }))
        }
        "migration_log_line" => {
            let r: LogLineRequest = parse(request)?;
            Ok(json!({ "line": migration::log_line(r.i, &r.kind, &r.text, &r.date) }))
        }
        "migration_local_date" => {
            let request: LocalDateRequest = parse(request)?;
            Ok(json!({ "date": migration::local_date(&request.text, request.utc_offset_seconds) }))
        }
        "migration_time" => {
            let request: TextRequest = parse(request)?;
            Ok(json!({ "seconds": super::time::time(&request.text) }))
        }
        "migration_message" => {
            let request: TextRequest = parse(request)?;
            Ok(json!({ "message": migration::message_from_json(&request.text) }))
        }
        "migration_read_log" => {
            let request: FilesRequest = parse(request)?;
            Ok(json!({ "entries": migration::read_log(&request.files) }))
        }
        "migration_cursor" => {
            let request: CursorRequest = parse(request)?;
            let cursor = match (&request.state, &request.host_json) {
                (Some(state), _) => migration::cursor_from_state(state),
                (None, Some(text)) => migration::cursor_from_host_json(text),
                (None, None) => migration::Cursor::default(),
            };
            reply(&cursor)
        }
        "migration_pick_chief" => {
            let request: ConversationsRequest = parse(request)?;
            Ok(json!({ "chief": migration::pick_chief(&request.conversations) }))
        }
        "migration_copy_skips" => {
            let request: NameRequest = parse(request)?;
            Ok(json!({ "skip": migration::copy_skips(&request.name) }))
        }
        "owner_brains_value" => {
            let request: BrainsRequest = parse(request)?;
            Ok(json!({ "value": brains_value(request) }))
        }
        _ => Err(OpError::Unknown),
    }
}
