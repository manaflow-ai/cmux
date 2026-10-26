//! `energy.set` and `energy.status` (p14-energy-033): the daemon's Energy
//! Saver, as [`crate::wake::EnergyMode`] holds it for every periodic owner
//! of this process.
//!
//! The cmux app resolves Energy Saver from the power inputs and its
//! `energy.saver` setting, and sends `energy.set` on each edge, after the
//! turn that changed it. That is an override of the daemon's own reading
//! (p14-energy-137 reads the power source, so the daemon follows AC and
//! battery after the app quits); `saver: null` clears it. Chrome splits the
//! same way: `BatterySaverModeManager` owns the state and each child process
//! gets one `SetBatterySaverMode` call per edge
//! (chrome/browser/performance_manager/public/user_tuning/battery_saver_mode_manager.h,
//! content/child/child_thread_impl.cc).
//!
//! The handler only stores the inputs and flips the mode: one atomic, the
//! mode's watchers woken on an edge, no I/O and no lock of its own. The
//! lines are answered before the `Command` parse (server/routes.rs), on the
//! connection's reader thread.

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::{MessageWriter, Response, origin_gate, responses::send_response};
use crate::mux::Mux;
use crate::wake::EnergyMode;

/// `identify` advertises this while the daemon answers both lines.
pub(crate) const CAPABILITY: &str = "energy-v1";
/// Sets or clears the app's override.
pub(in crate::server) const SET: &str = "energy.set";
/// Reads the mode, its source and both inputs.
pub(in crate::server) const STATUS: &str = "energy.status";
/// The `cmd` names this module answers.
pub(in crate::server) const COMMANDS: [&str; 2] = [SET, STATUS];

/// The `cmd` names this module answers (server/routes.rs).
pub(in crate::server) const ROUTES: &[crate::server::routes::Route] =
    &[crate::server::routes::Route {
        names: &[crate::server::routes::RouteName::OneOf(&COMMANDS)],
        stage: crate::server::FrameStage::Route,
        entry: |line| try_handle(line.mux, line.client, line.message, line.writer),
    }];

/// Why Energy Saver is on: the app's `EnergyPolicy.Reason`, spelled the same
/// on the wire.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum SaverReason {
    LowPowerMode,
    Battery,
    Thermal,
    Setting,
}

impl SaverReason {
    const ALL: [Self; 4] = [Self::LowPowerMode, Self::Battery, Self::Thermal, Self::Setting];

    fn code(self) -> u8 {
        match self {
            Self::LowPowerMode => 1,
            Self::Battery => 2,
            Self::Thermal => 3,
            Self::Setting => 4,
        }
    }

    fn from_code(code: u8) -> Option<Self> {
        Self::ALL.into_iter().find(|reason| reason.code() == code)
    }
}

/// Who decides the mode now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EnergySource {
    /// The app's `energy.set` override.
    App,
    /// The daemon's own reading.
    Daemon,
}

/// What `energy.status` reports, from one load of the inputs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct EnergyStatus {
    /// Energy Saver is on for this process.
    pub saver: bool,
    pub source: EnergySource,
    /// The override's reason while the app holds the saver on.
    pub reason: Option<SaverReason>,
    /// The app's override, `None` while it holds none.
    #[serde(rename = "override")]
    pub app_override: Option<bool>,
    /// The daemon's own reading (off until p14-energy-137 reads the power source).
    pub reading: bool,
}

// The inputs, packed so one atomic holds them: a reader never sees an
// override with another override's reason.
const READING: u8 = 0b1;
const OVERRIDE_SHIFT: u8 = 1;
const OVERRIDE_MASK: u8 = 0b11 << OVERRIDE_SHIFT;
const OVERRIDE_OFF: u8 = 1;
const OVERRIDE_ON: u8 = 2;
const REASON_SHIFT: u8 = 3;

/// The daemon's Energy Saver: its own reading, the app's override, and the
/// [`EnergyMode`] they resolve to. One per [`Mux`].
pub struct DaemonEnergy {
    mode: Arc<EnergyMode>,
    inputs: AtomicU8,
}

impl Default for DaemonEnergy {
    fn default() -> Self {
        Self { mode: EnergyMode::new(false), inputs: AtomicU8::new(0) }
    }
}

impl DaemonEnergy {
    /// The mode every periodic owner of this process watches.
    #[cfg_attr(not(test), expect(dead_code, reason = "read by p14-energy-034 and 137"))]
    pub(crate) fn mode(&self) -> &Arc<EnergyMode> {
        &self.mode
    }

    /// Sets the app's override (`None` clears it). Returns whether the mode
    /// changed.
    pub fn set_override(&self, saver: Option<bool>, reason: Option<SaverReason>) -> bool {
        let packed = match saver {
            None => 0,
            Some(false) => OVERRIDE_OFF << OVERRIDE_SHIFT,
            Some(true) => {
                (OVERRIDE_ON << OVERRIDE_SHIFT)
                    | (reason.map_or(0, SaverReason::code) << REASON_SHIFT)
            }
        };
        self.store(|inputs| (inputs & READING) | packed)
    }

    /// Sets the daemon's own reading (p14-energy-137). Returns whether the
    /// mode changed.
    #[cfg_attr(not(test), expect(dead_code, reason = "written by p14-energy-137"))]
    pub(crate) fn set_reading(&self, saver: bool) -> bool {
        self.store(|inputs| (inputs & !READING) | u8::from(saver))
    }

    /// The mode, its source and both inputs now.
    pub fn status(&self) -> EnergyStatus {
        let inputs = self.inputs.load(Ordering::Acquire);
        let app_override = match (inputs & OVERRIDE_MASK) >> OVERRIDE_SHIFT {
            OVERRIDE_OFF => Some(false),
            OVERRIDE_ON => Some(true),
            _ => None,
        };
        let reading = inputs & READING != 0;
        EnergyStatus {
            saver: app_override.unwrap_or(reading),
            source: if app_override.is_some() { EnergySource::App } else { EnergySource::Daemon },
            reason: (app_override == Some(true))
                .then(|| SaverReason::from_code(inputs >> REASON_SHIFT))
                .flatten(),
            app_override,
            reading,
        }
    }

    /// Stores `change(inputs)` and flips the mode to what the inputs resolve
    /// to. A writer that raced this one may have flipped the mode from older
    /// inputs after this store, so each writer flips again until the mode
    /// matches the inputs it reads last: the last store always wins.
    fn store(&self, change: impl Fn(u8) -> u8) -> bool {
        let previous = self
            .inputs
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |inputs| Some(change(inputs)));
        debug_assert!(previous.is_ok(), "the closure always stores");
        let mut changed = false;
        loop {
            let saver = self.status().saver;
            changed |= self.mode.set_saver(saver);
            if self.status().saver == saver {
                return changed;
            }
        }
    }
}

/// `energy.set`'s fields after `cmd` and `id`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SetRequest {
    saver: Option<bool>,
    #[serde(default)]
    reason: Option<SaverReason>,
}

/// Answers an `energy.set` or `energy.status` line; `None` for any other line.
pub(in crate::server) fn try_handle(
    mux: &Arc<Mux>,
    client: u64,
    message: &str,
    writer: &MessageWriter,
) -> Option<bool> {
    if !message.contains("energy.") {
        return None;
    }
    let Ok(Value::Object(mut fields)) = crate::line_parses::parse::<Value>(message) else {
        return None;
    };
    let cmd = fields.remove("cmd");
    let cmd = cmd.as_ref().and_then(Value::as_str).filter(|cmd| COMMANDS.contains(cmd))?;
    let id = fields.remove("id");
    let local = mux.control_clients.is_unix(client) && !mux.is_remote_client(client);
    let result = if cmd == STATUS {
        status(mux, local, &fields)
    } else {
        set(mux, local && origin_gate::is_user(mux, client), fields)
    };
    Some(reply(writer, id, result))
}

fn status(mux: &Mux, local: bool, fields: &Map<String, Value>) -> Result<Value, &'static str> {
    if !local {
        return Err("energy.not_trusted");
    }
    if !fields.is_empty() {
        return Err("energy.bad_request");
    }
    serde_json::to_value(mux.energy.status()).map_err(|_| "energy.bad_request")
}

fn set(mux: &Mux, trusted: bool, fields: Map<String, Value>) -> Result<Value, &'static str> {
    if !trusted {
        return Err("energy.not_trusted");
    }
    if !fields.contains_key("saver") {
        return Err("energy.bad_request");
    }
    let request: SetRequest =
        serde_json::from_value(Value::Object(fields)).map_err(|_| "energy.bad_request")?;
    if request.saver != Some(true) && request.reason.is_some() {
        return Err("energy.bad_request");
    }
    let changed = mux.energy.set_override(request.saver, request.reason);
    Ok(json!({"changed": changed, "saver": mux.energy.status().saver}))
}

fn reply(writer: &MessageWriter, id: Option<Value>, result: Result<Value, &str>) -> bool {
    let (ok, data, error_code) = match result {
        Ok(value) => (true, Some(value), None),
        Err(code) => (false, None, Some(code.to_owned())),
    };
    let error = error_code.as_deref().map(|code| match code {
        "energy.not_trusted" => "energy requests need the trusted local connection".to_owned(),
        _ => "bad request: energy.status takes no fields; energy.set takes saver (true, false \
              or null) and, with true, a reason"
            .to_owned(),
    });
    send_response(writer, Response { id, ok, data, error, error_code, error_delivery: None })
}

#[cfg(test)]
#[path = "energy_op_tests.rs"]
mod tests;
