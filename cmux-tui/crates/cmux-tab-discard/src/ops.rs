//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `tab_discard_*`). One [`TabDiscard`] per app holds the probe
//! history of its hidden pages; every other op is pure.
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `tab_discard_setting` | `{setting}` | `{enabled, mode, hidden_seconds, discards_automatically}`: the setting in force |
//! | `tab_discard_threshold` | `{setting, pressure}` | `{seconds}`: seconds hidden before a page is discarded (null: never) |
//! | `tab_discard_plan` | `{setting, pressure, candidates}` | [`Plan`]: the pages to discard now |
//! | `tab_discard_freeze_plan` | `{setting, candidates}` | [`Plan`]: the pages to freeze now |
//! | `tab_discard_exemption` | `{setting, candidate}` | `{exemption}` (null: none) |
//! | `tab_discard_probe` | `{key, probe, pressure, shows_form_submission}` | `{exemption}`: what the page's answer right before a discard keeps (it records an answer); null when it may go |
//! | `tab_discard_freeze_probe` | `{key, probe}` | `{keep}`: the answer right before a freeze (recorded); true keeps the page awake |
//! | `tab_discard_probe_doubted` | `{key, step}` | `{doubted}` |
//! | `tab_discard_record` | `{key, probe, step}` | `{doubted}`: records one probe for `step` (a miss counts) |
//! | `tab_discard_probe_verdict` | `{probe, pressure, doubted, shows_form_submission}` | `{exemption, stops_when_frozen, keep_reason}`: what one answer says, recording nothing |
//! | `tab_discard_shown` | `{key}` | `{}`: the page showed; its missed probes start again |
//! | `tab_discard_forget` | `{key}` | `{}`: the page closed |

use crate::plan::{self, Candidate, Plan, Pressure};
use crate::probe::{PageProbe, ProbeHistory, Step};
use crate::setting::Setting;
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

/// Why an op failed.
#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of the table's.
    UnknownOp(String),
    /// The request is not the JSON the op takes.
    Invalid(String),
}

/// The app's one set of rules: the probe history of its hidden pages.
#[derive(Debug, Default)]
pub struct TabDiscard {
    history: ProbeHistory,
}

#[derive(Deserialize)]
struct SettingRequest {
    #[serde(default)]
    setting: Setting,
}

#[derive(Deserialize)]
struct PlanRequest {
    #[serde(default)]
    setting: Setting,
    #[serde(default)]
    pressure: Pressure,
    #[serde(default)]
    candidates: Vec<Candidate>,
}

#[derive(Deserialize)]
struct ExemptionRequest {
    #[serde(default)]
    setting: Setting,
    candidate: Candidate,
}

#[derive(Deserialize)]
struct ProbeRequest {
    key: String,
    probe: PageProbe,
    #[serde(default)]
    pressure: Pressure,
    #[serde(default)]
    shows_form_submission: bool,
}

#[derive(Deserialize)]
struct RecordRequest {
    key: String,
    probe: PageProbe,
    #[serde(default)]
    step: Step,
}

#[derive(Deserialize)]
struct VerdictRequest {
    #[serde(default)]
    probe: PageProbe,
    #[serde(default)]
    pressure: Pressure,
    #[serde(default)]
    doubted: bool,
    #[serde(default)]
    shows_form_submission: bool,
}

#[derive(Deserialize)]
struct KeyRequest {
    key: String,
    #[serde(default)]
    step: Step,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn encode(plan: &Plan) -> Value {
    serde_json::to_value(plan).unwrap_or(Value::Null)
}

impl TabDiscard {
    pub fn new() -> Self {
        Self::default()
    }

    /// True for the ops this answers.
    pub fn serves(op: &str) -> bool {
        op.starts_with("tab_discard_")
    }

    /// Runs `op` on `request` (a JSON object; null means `{}`).
    pub fn call(&mut self, op: &str, request: Value) -> Result<Value, OpError> {
        let request = if request.is_null() { json!({}) } else { request };
        match op {
            "tab_discard_setting" => {
                let SettingRequest { setting } = parse(request)?;
                Ok(json!({
                    "enabled": setting.is_enabled(),
                    "mode": setting.effective_mode(),
                    "hidden_seconds": plan::threshold(&setting, Pressure::Normal),
                    "discards_automatically": setting.discards_automatically,
                }))
            }
            "tab_discard_threshold" => {
                let PlanRequest { setting, pressure, .. } = parse(request)?;
                Ok(json!({ "seconds": plan::threshold(&setting, pressure) }))
            }
            "tab_discard_plan" => {
                let PlanRequest { setting, pressure, candidates } = parse(request)?;
                Ok(encode(&plan::plan(&setting, pressure, &candidates)))
            }
            "tab_discard_freeze_plan" => {
                let PlanRequest { setting, candidates, .. } = parse(request)?;
                Ok(encode(&plan::freeze_plan(&setting, &candidates)))
            }
            "tab_discard_exemption" => {
                let ExemptionRequest { setting, candidate } = parse(request)?;
                Ok(json!({ "exemption": plan::exemption(&candidate, &setting) }))
            }
            "tab_discard_probe" => {
                let ProbeRequest { key, probe, pressure, shows_form_submission } = parse(request)?;
                // The freeze probe counts the misses (it runs beside this one); this one records
                // an answer only.
                let doubted = if probe.answered {
                    self.history.record(probe, &key, Step::Discard)
                } else {
                    self.history.doubted(&key, Step::Discard)
                };
                Ok(
                    json!({ "exemption": probe.keep_reason(pressure, doubted, shows_form_submission) }),
                )
            }
            "tab_discard_freeze_probe" => {
                let ProbeRequest { key, probe, .. } = parse(request)?;
                let doubted = self.history.record(probe, &key, Step::Freeze);
                Ok(json!({ "keep": probe.stops_when_frozen() || doubted }))
            }
            "tab_discard_record" => {
                let RecordRequest { key, probe, step } = parse(request)?;
                Ok(json!({ "doubted": self.history.record(probe, &key, step) }))
            }
            "tab_discard_probe_verdict" => {
                let VerdictRequest { probe, pressure, doubted, shows_form_submission } =
                    parse(request)?;
                Ok(json!({
                    "exemption": probe.exemption(),
                    "stops_when_frozen": probe.stops_when_frozen(),
                    "keep_reason": probe.keep_reason(pressure, doubted, shows_form_submission),
                }))
            }
            "tab_discard_probe_doubted" => {
                let KeyRequest { key, step } = parse(request)?;
                Ok(json!({ "doubted": self.history.doubted(&key, step) }))
            }
            "tab_discard_shown" => {
                let KeyRequest { key, .. } = parse(request)?;
                self.history.clear_misses(&key);
                Ok(json!({}))
            }
            "tab_discard_forget" => {
                let KeyRequest { key, .. } = parse(request)?;
                self.history.forget(&key);
                Ok(json!({}))
            }
            other => Err(OpError::UnknownOp(other.to_owned())),
        }
    }
}
