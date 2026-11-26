//! Tunables: ports the pure rules of CmuxNextDesign/Tunables/BrowserChromeMetric.swift and
//! BrowserChromeTuning.swift ([`browser_chrome`]), CmuxNextDesign/FloatingPane/FloatingPaneTunables.swift
//! ([`floating_pane`]), CmuxNextDesignTokens/Tunables/TunableDescriptor.swift with the kind's clamp
//! and Debug Settings' number formatting ([`descriptor`]), and CmuxNextDesign/TokenMemo.swift's
//! keep-or-compute rules ([`memo`]). BrowserChromeReferenceFiles.swift is file IO only (no rule
//! to port).
//!
//! Ops (`tokens.NAME`): `tunables_read_cadences`, `tunables_clamp`, `tunables_format_number`,
//! `tunables_format_value`, `tunables_snap`, `tunables_display`, `tunables_unit_suffix`,
//! `tunables_browser_chrome_metric`, `tunables_browser_chrome_key`,
//! `tunables_browser_chrome_default`, `tunables_browser_chrome_override`,
//! `tunables_browser_chrome_value`, `tunables_browser_chrome_chip_leading`,
//! `tunables_browser_chrome_text_origin`, `tunables_browser_chrome_share`,
//! `tunables_browser_chrome_descriptors`, `tunables_floating_pane_descriptors`,
//! `tunables_floating_pane_look`, `tunables_memo_run`.

pub mod browser_chrome;
pub mod descriptor;
pub mod floating_pane;
pub mod memo;

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::density::{DensityPreset, DensityTokens};
use browser_chrome::BrowserChromeMetric;
use descriptor::{TunableKind, TunableReadCadence, TunableUnit, TunableValue};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClampRequest {
    kind: TunableKind,
    value: TunableValue,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NumberRequest {
    number: f64,
    #[serde(default)]
    unit: Option<TunableUnit>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FormatValueRequest {
    value: TunableValue,
    kind: TunableKind,
    #[serde(default = "on")]
    on: String,
    #[serde(default = "off")]
    off: String,
}

fn on() -> String {
    "On".into()
}
fn off() -> String {
    "Off".into()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapRequest {
    number: f64,
    range: (f64, f64),
    step: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UnitRequest {
    unit: TunableUnit,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MetricRequest {
    metric: BrowserChromeMetric,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MetricReply {
    raw: &'static str,
    token: Option<&'static str>,
    density_key: Option<&'static str>,
    label: &'static str,
    help: &'static str,
    range: (f64, f64),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyRequest {
    metric: BrowserChromeMetric,
    density: DensityPreset,
}

/// A density by preset (`density`) or in full (`tokens`).
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DefaultRequest {
    metric: BrowserChromeMetric,
    #[serde(default)]
    density: Option<DensityPreset>,
    #[serde(default)]
    tokens: Option<DensityTokens>,
    #[serde(default)]
    row: Option<f64>,
    #[serde(default)]
    overrides: BTreeMap<String, TunableValue>,
}

impl DefaultRequest {
    fn tokens(&self) -> Result<DensityTokens, OpError> {
        match (&self.tokens, self.density) {
            (Some(t), _) => Ok(t.clone()),
            (None, Some(d)) => Ok(d.tokens().clone()),
            (None, None) => Err(OpError::Invalid("density or tokens is required".into())),
        }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OverrideRequest {
    metric: BrowserChromeMetric,
    tokens_id: String,
    #[serde(default)]
    overrides: BTreeMap<String, TunableValue>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BarRequest {
    bar: f64,
    #[serde(default)]
    chrome_column: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShareRequest {
    points: f64,
    row: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LookRequest {
    #[serde(default)]
    overrides: BTreeMap<String, TunableValue>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MemoRunRequest {
    #[serde(default)]
    state: memo::MemoState,
    events: Vec<memo::MemoEvent>,
}

/// Runs the `tokens.tunables_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "tunables_read_cadences" => {
            reply(&TunableReadCadence::ALL.iter().map(|c| c.raw()).collect::<Vec<_>>())
        }
        "tunables_clamp" => {
            let r: ClampRequest = parse(request)?;
            reply(&r.kind.clamp(&r.value))
        }
        "tunables_format_number" => {
            let r: NumberRequest = parse(request)?;
            let text = match r.unit {
                Some(unit) => descriptor::format_with_unit(r.number, unit),
                None => descriptor::format_number(r.number),
            };
            reply(&text)
        }
        "tunables_format_value" => {
            let r: FormatValueRequest = parse(request)?;
            reply(&descriptor::format_value(&r.value, &r.kind, &r.on, &r.off))
        }
        "tunables_snap" => {
            let r: SnapRequest = parse(request)?;
            reply(&descriptor::snap(r.number, r.range, r.step))
        }
        "tunables_display" => {
            let r: NumberRequest = parse(request)?;
            let unit = r.unit.ok_or_else(|| OpError::Invalid("unit is required".into()))?;
            reply(&descriptor::display_number(r.number, unit))
        }
        "tunables_unit_suffix" => {
            let r: UnitRequest = parse(request)?;
            reply(&r.unit.suffix())
        }
        "tunables_browser_chrome_metric" => {
            let r: MetricRequest = parse(request)?;
            let m = r.metric;
            reply(&MetricReply {
                raw: m.raw(),
                token: m.token(),
                density_key: m.density_key(),
                label: m.label(),
                help: m.help(),
                range: m.range(),
            })
        }
        "tunables_browser_chrome_key" => {
            let r: KeyRequest = parse(request)?;
            reply(&browser_chrome::key(r.metric, r.density))
        }
        "tunables_browser_chrome_default" => {
            let r: DefaultRequest = parse(request)?;
            reply(&browser_chrome::default_value(r.metric, &r.tokens()?, r.row))
        }
        "tunables_browser_chrome_value" => {
            let r: DefaultRequest = parse(request)?;
            reply(&browser_chrome::value(r.metric, &r.tokens()?, r.row, &r.overrides))
        }
        "tunables_browser_chrome_override" => {
            let r: OverrideRequest = parse(request)?;
            reply(&browser_chrome::override_value(r.metric, &r.tokens_id, &r.overrides))
        }
        "tunables_browser_chrome_chip_leading" => {
            let r: BarRequest = parse(request)?;
            reply(&browser_chrome::chip_leading(r.bar, r.chrome_column))
        }
        "tunables_browser_chrome_text_origin" => {
            let r: BarRequest = parse(request)?;
            reply(&browser_chrome::text_origin(r.bar, r.chrome_column))
        }
        "tunables_browser_chrome_share" => {
            let r: ShareRequest = parse(request)?;
            reply(&browser_chrome::share(r.points, r.row))
        }
        "tunables_browser_chrome_descriptors" => reply(
            &json!({"section": browser_chrome::section(), "descriptors": browser_chrome::descriptors()}),
        ),
        "tunables_floating_pane_descriptors" => reply(
            &json!({"section": floating_pane::section(), "descriptors": floating_pane::descriptors()}),
        ),
        "tunables_floating_pane_look" => {
            let r: LookRequest = parse(request)?;
            let look = floating_pane::look(&r.overrides);
            let see_through = look.is_see_through();
            let mut value =
                serde_json::to_value(&look).map_err(|e| OpError::Invalid(e.to_string()))?;
            value["isSeeThrough"] = json!(see_through);
            Ok(value)
        }
        "tunables_memo_run" => {
            let r: MemoRunRequest = parse(request)?;
            let (reads, state) = memo::run(r.state, &r.events);
            reply(&json!({"reads": reads, "state": state}))
        }
        _ => Err(OpError::Unknown),
    }
}
