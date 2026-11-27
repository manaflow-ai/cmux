//! The device rules over one JSON channel (ops `rd_devices_*`), the shape the app's C ABI
//! (`cmux_layout_reducer_json`) carries: the Set Up / Start runs by device id, and the stateless rules
//! (the hub link, Settings > Devices, Your Devices).

use super::home::{self, Discovery, HomeDevice};
use super::hub::{self, BuildSpace, ReconcileInputs, StartupError};
use super::settings::{
    self, AuditEntry, CheckOutcome, Connection, Failure, HubStatus, NoHub, Platform, RelayDraft,
    RelaySecret,
};
use super::setup::{Line, Run, RunStop, Setup, SetupRow, Verb};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};

/// The Set Up / Start runs this Mac drives.
#[derive(Default)]
pub struct RdDevices {
    setup: Setup,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, String> {
    serde_json::from_value(request).map_err(|e| e.to_string())
}

fn encode(value: impl serde::Serialize) -> Result<Value, String> {
    serde_json::to_value(value).map_err(|e| e.to_string())
}

#[derive(Deserialize)]
struct Id {
    id: String,
}

#[derive(Deserialize)]
struct On {
    on: bool,
}

#[derive(Deserialize)]
struct RunRequest {
    id: String,
    verb: Verb,
}

#[derive(Deserialize)]
struct LineRequest {
    id: String,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    line: Option<Value>,
}

#[derive(Deserialize)]
struct EndRequest {
    id: String,
    #[serde(default)]
    stop: Option<RunStop>,
}

#[derive(Deserialize)]
struct RowRequest {
    id: String,
    is_mac: bool,
    online: bool,
    #[serde(default)]
    allows_requests: Option<bool>,
}

#[derive(Deserialize)]
struct RowMakeRequest {
    is_mac: bool,
    online: bool,
    #[serde(default)]
    verbs: Option<BTreeSet<Verb>>,
    #[serde(default)]
    run: Option<Run>,
    #[serde(default)]
    allows_requests: Option<bool>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct BundleRequest {
    selection_bundle: Option<String>,
    storage_namespace: Option<String>,
    bundle_id: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SpaceRequest {
    refused: bool,
    header: Option<String>,
}

#[derive(Deserialize)]
struct UserRequest {
    signed_in: bool,
    #[serde(default)]
    id: Option<String>,
}

#[derive(Deserialize)]
struct StatusRequest {
    hub: HubStatus,
    connection: Connection,
}

#[derive(Deserialize)]
struct ConnectionRequest {
    connection: Connection,
}

#[derive(Deserialize)]
struct HistoryRequest {
    entries: Vec<AuditEntry>,
    #[serde(default)]
    names: HashMap<String, String>,
}

#[derive(Deserialize)]
struct Seconds {
    seconds: f64,
}

#[derive(Deserialize)]
struct RelayRequest {
    draft: RelayDraft,
    #[serde(default)]
    existing: Option<RelaySecret>,
}

#[derive(Deserialize)]
struct OutcomeRequest {
    outcome: CheckOutcome,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct DeviceRequest {
    platform: Option<Platform>,
    online: bool,
    seen: Option<String>,
    this_device: bool,
    listed: bool,
    name: String,
}

#[derive(Deserialize)]
struct NameRequest {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct DevicesRequest {
    devices: Vec<HomeDevice>,
}

#[derive(Deserialize)]
struct SetupDevicesRequest {
    configured: bool,
    #[serde(default)]
    restoring: bool,
}

#[derive(Deserialize)]
struct FirstUseRequest {
    has_used_before: bool,
    is_sharing: bool,
}

impl RdDevices {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn serves(op: &str) -> bool {
        op.starts_with("rd_devices_")
    }

    pub fn call(&mut self, op: &str, request: Value) -> Result<Value, String> {
        match op {
            // Set Up cmux / Start cmux.
            "rd_devices_setup_set_runner" => {
                let On { on } = parse(request)?;
                self.setup.set_runner(on);
                Ok(json!({ "verbs": encode(&self.setup.verbs)? }))
            }
            "rd_devices_setup_run" => {
                let r: RunRequest = parse(request)?;
                let started = self.setup.run(r.verb, &r.id);
                Ok(json!({ "started": started, "run": encode(self.setup.runs.get(&r.id))? }))
            }
            "rd_devices_setup_line" => {
                let r: LineRequest = parse(request)?;
                let line = match (r.text, r.line) {
                    (Some(text), _) => Line::parse(&text),
                    (None, Some(value)) => Line::of_value(&value),
                    (None, None) => None,
                };
                let Some(line) = line else { return Ok(json!({ "taken": false })) };
                let run = self.setup.line(&r.id, line);
                Ok(json!({ "taken": run.is_some(), "run": encode(run)? }))
            }
            "rd_devices_setup_end" => {
                let r: EndRequest = parse(request)?;
                let ended = self.setup.end(&r.id, r.stop);
                Ok(json!({ "ended": encode(ended)?, "run": encode(self.setup.runs.get(&r.id))? }))
            }
            "rd_devices_setup_dismiss" => {
                let Id { id } = parse(request)?;
                Ok(json!({ "dismissed": self.setup.dismiss(&id) }))
            }
            "rd_devices_setup_row" => {
                let r: RowRequest = parse(request)?;
                let row = self.setup.row(&r.id, r.is_mac, r.online);
                encode(match r.allows_requests {
                    Some(allows) => row.blocking(allows),
                    None => row,
                })
            }
            "rd_devices_setup_row_make" => {
                let r: RowMakeRequest = parse(request)?;
                let row = SetupRow::make(r.is_mac, r.online, r.verbs.as_ref(), r.run);
                encode(match r.allows_requests {
                    Some(allows) => row.blocking(allows),
                    None => row,
                })
            }
            "rd_devices_setup_line_parse" => {
                let LineRequest { text, line, .. } = parse(request)?;
                encode(
                    text.as_deref()
                        .and_then(Line::parse)
                        .or_else(|| line.as_ref().and_then(Line::of_value)),
                )
            }
            // The hub link.
            "rd_devices_reconcile" => {
                let inputs: ReconcileInputs = parse(request)?;
                encode(hub::reconcile(&inputs))
            }
            "rd_devices_startup_error" => {
                let error: StartupError = parse(request)?;
                Ok(json!(hub::startup_error_code(&error)))
            }
            "rd_devices_hub_bundle" => {
                let r: BundleRequest = parse(request)?;
                Ok(json!(hub::hub_bundle(
                    r.selection_bundle.as_deref(),
                    r.storage_namespace.as_deref(),
                    r.bundle_id.as_deref()
                )))
            }
            "rd_devices_build_space" => {
                let r: SpaceRequest = parse(request)?;
                let space = BuildSpace::of(r.refused, r.header.as_deref());
                Ok(
                    json!({ "space": encode(&space)?, "allows_remote_hub": space.allows_remote_hub() }),
                )
            }
            "rd_devices_user_id" => {
                let r: UserRequest = parse(request)?;
                Ok(json!(hub::user_id(r.signed_in, r.id.as_deref())))
            }
            // Settings > Devices.
            "rd_devices_status" => {
                let r: StatusRequest = parse(request)?;
                Ok(json!({
                    "status": encode(settings::hub_status(r.hub, r.connection))?,
                    "redialing": settings::redialing(r.hub, r.connection),
                }))
            }
            "rd_devices_no_hub" => {
                let r: NoHub = parse(request)?;
                encode(settings::no_hub_card(&r))
            }
            "rd_devices_redials" => {
                let ConnectionRequest { connection } = parse(request)?;
                Ok(json!(settings::redials(connection)))
            }
            "rd_devices_history" => {
                let r: HistoryRequest = parse(request)?;
                let rows: Vec<_> =
                    r.entries.iter().map(|e| settings::history_row(e, &r.names)).collect();
                encode(rows)
            }
            "rd_devices_duration_text" => {
                let Seconds { seconds } = parse(request)?;
                Ok(json!(settings::duration_text(seconds)))
            }
            "rd_devices_relay_secret" => {
                let r: RelayRequest = parse(request)?;
                encode(settings::draft_secret(&r.draft, r.existing.as_ref()))
            }
            "rd_devices_relay_validate" => {
                let r: RelayRequest = parse(request)?;
                Ok(match settings::validate_relay(&r.draft, r.existing.as_ref()) {
                    Ok(save) => json!({ "ok": encode(save)? }),
                    Err(error) => json!({ "error": encode(error)? }),
                })
            }
            "rd_devices_relay_mode" => {
                let mode = parse(request)?;
                encode(settings::mode_text(mode))
            }
            "rd_devices_check_result" => {
                let OutcomeRequest { outcome } = parse(request)?;
                encode(settings::check_result(outcome))
            }
            "rd_devices_error_message" => {
                let failure: Failure = parse(request)?;
                encode(settings::failure_message(&failure))
            }
            "rd_devices_device_row" => {
                let r: DeviceRequest = parse(request)?;
                Ok(json!({
                    "platform": encode(settings::platform_label(r.platform))?,
                    "presence": encode(settings::presence(r.online || r.this_device, r.seen.as_deref()))?,
                    "screen": encode(settings::screen_action(r.platform, r.this_device, r.online))?,
                    "remove": encode(settings::remove_confirm(r.this_device, &r.name))?,
                }))
            }
            "rd_devices_open_screen" => {
                let r: DeviceRequest = parse(request)?;
                encode(settings::open_screen_refusal(r.listed, r.this_device, r.platform, r.online))
            }
            "rd_devices_rename" => {
                let NameRequest { name } = parse(request)?;
                Ok(json!(settings::rename_name(name.as_deref())))
            }
            "rd_devices_event" => {
                #[derive(Deserialize)]
                struct EventRequest {
                    event: String,
                }
                let EventRequest { event } = parse(request)?;
                Ok(
                    json!({ "text": encode(settings::event_text(&event))?, "tone": settings::event_tone(&event) }),
                )
            }
            // Your Devices.
            "rd_devices_home_listed" => {
                let DevicesRequest { devices } = parse(request)?;
                Ok(json!(home::listed(&devices)))
            }
            "rd_devices_home_row_state" => {
                let device: HomeDevice = parse(request)?;
                encode(home::row_state(&device))
            }
            "rd_devices_home_empty_note" => {
                let discovery: Discovery = parse(request)?;
                encode(home::empty_note(&discovery))
            }
            "rd_devices_home_setup_devices" => {
                let r: SetupDevicesRequest = parse(request)?;
                encode(home::setup_devices(r.configured, r.restoring))
            }
            "rd_devices_home_first_use" => {
                let r: FirstUseRequest = parse(request)?;
                Ok(json!(home::shows_first_use(r.has_used_before, r.is_sharing)))
            }
            _ => Err(format!("unknown op {op}")),
        }
    }
}

#[cfg(test)]
#[path = "ops_tests.rs"]
mod tests;
