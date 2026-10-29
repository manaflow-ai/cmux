//! `energy.set` and `energy.status`: the daemon's Energy
//! Saver, as [`crate::wake::EnergyMode`] holds it for every periodic owner
//! of this process.
//!
//! The cmux app resolves Energy Saver from the power inputs and its
//! `energy.saver` setting, and sends `energy.set` on each edge, after the
//! turn that changed it. That is an override of the daemon's own reading,
//! which follows the app's rule from the same setting and the Mac's own
//! power inputs (server/energy_rule.rs), so the daemon
//! decides as the app would after it quits. `saver: null` clears the
//! override, and so does the end of the control connection that set it, so
//! a quit or crashed app (or one whose link dropped) leaves no override
//! behind. Its `offForNow` ("Turn Off for Now") stays until the battery ->
//! AC edge or the app's next word. Chrome splits the
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
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use super::energy_rule::{self, PowerFacts, SaverSetting};
use super::{MessageWriter, Response, origin_gate, responses::send_response};
use crate::mux::Mux;
use crate::wake::EnergyMode;

/// `identify` advertises this while the daemon answers both lines.
pub(crate) const CAPABILITY: &str = "energy-v1";
/// `identify` advertises this while `energy.set` also takes `offForNow` and
/// the daemon's own reading follows the app's rule (server/energy_rule.rs).
pub(crate) const RULE_CAPABILITY: &str = "energy-v2";
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
    /// Why the saver is on, from the source that decides; `None` while it
    /// is off.
    pub reason: Option<SaverReason>,
    /// The app's override, `None` while it holds none.
    #[serde(rename = "override")]
    pub app_override: Option<bool>,
    /// The daemon's own reading by the app's rule (server/energy_rule.rs):
    /// off until the settings owner read `energy.saver` and the power inputs
    /// are followed (mux/power_source.rs; never where the daemon reads no
    /// power inputs, nor while the `energySaver` feature is off).
    pub reading: bool,
    /// `energy.saver` as the daemon read it; `None` until it is read.
    pub setting: Option<SaverSetting>,
    /// "Turn Off for Now" holds, as the app last told it.
    #[serde(rename = "offForNow")]
    pub off_for_now: bool,
}

/// Everything the mode resolves from, packed into the low [`SETTER_SHIFT`]
/// bits of one atomic with the override's setter above them: a reader never
/// sees an override with another override's reason, and a departing client
/// clears only the override it set.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Inputs {
    /// The app's override and, with `Some(true)`, its reason.
    app_override: Option<bool>,
    reason: Option<SaverReason>,
    /// `energy.saver`, once the settings owner read it.
    setting: Option<SaverSetting>,
    /// "Turn Off for Now", as the app last told it.
    off_for_now: bool,
    /// The power facts, once the power inputs are followed.
    facts: Option<PowerFacts>,
}

const OVERRIDE_MASK: u64 = 0b11;
const OVERRIDE_OFF: u64 = 1;
const OVERRIDE_ON: u64 = 2;
const REASON_SHIFT: u32 = 2;
const SETTING_SHIFT: u32 = 5;
const OFF_FOR_NOW: u64 = 1 << 8;
const FACTS_KNOWN: u64 = 1 << 9;
const ON_BATTERY: u64 = 1 << 10;
const LOW_BATTERY: u64 = 1 << 11;
const LOW_POWER_MODE: u64 = 1 << 12;
const HOT: u64 = 1 << 13;
/// The setter holds the low 48 bits of its control client id: ids count up
/// by one per connection and never reach 2^48.
const SETTER_SHIFT: u32 = 16;
const INPUTS: u64 = (1 << SETTER_SHIFT) - 1;

impl Inputs {
    fn unpack(state: u64) -> Self {
        let app_override = match state & OVERRIDE_MASK {
            OVERRIDE_OFF => Some(false),
            OVERRIDE_ON => Some(true),
            _ => None,
        };
        let bit = |mask: u64| state & mask != 0;
        Self {
            app_override,
            reason: SaverReason::from_code(((state >> REASON_SHIFT) & 0b111) as u8),
            setting: SaverSetting::from_code(((state >> SETTING_SHIFT) & 0b111) as u8),
            off_for_now: bit(OFF_FOR_NOW),
            facts: bit(FACTS_KNOWN).then(|| PowerFacts {
                on_battery: bit(ON_BATTERY),
                low_battery: bit(LOW_BATTERY),
                low_power_mode: bit(LOW_POWER_MODE),
                hot: bit(HOT),
            }),
        }
    }

    /// The low bits of the state; the caller keeps or replaces the setter.
    fn pack(self) -> u64 {
        let flag = |on: bool, mask: u64| if on { mask } else { 0 };
        let (app_override, reason) = match self.app_override {
            None => (0, 0),
            Some(false) => (OVERRIDE_OFF, 0),
            Some(true) => (OVERRIDE_ON, self.reason.map_or(0, SaverReason::code)),
        };
        let facts = self.facts.map_or(0, |facts| {
            FACTS_KNOWN
                | flag(facts.on_battery, ON_BATTERY)
                | flag(facts.low_battery, LOW_BATTERY)
                | flag(facts.low_power_mode, LOW_POWER_MODE)
                | flag(facts.hot, HOT)
        });
        app_override
            | (u64::from(reason) << REASON_SHIFT)
            | (u64::from(self.setting.map_or(0, SaverSetting::code)) << SETTING_SHIFT)
            | flag(self.off_for_now, OFF_FOR_NOW)
            | facts
    }

    /// Why the daemon's own reading turns the saver on, if it does.
    fn reading(self) -> Option<SaverReason> {
        energy_rule::reason(self.setting?, self.off_for_now, self.facts?)
    }
}

/// `client` in the setter bits.
fn setter(client: u64) -> u64 {
    client << SETTER_SHIFT
}

/// The daemon's Energy Saver: its own reading by the app's rule, the app's
/// override with the control client that set it, and the [`EnergyMode`]
/// they resolve to. One per [`Mux`].
pub struct DaemonEnergy {
    mode: Arc<EnergyMode>,
    state: AtomicU64,
}

impl Default for DaemonEnergy {
    fn default() -> Self {
        Self { mode: EnergyMode::new(false), state: AtomicU64::new(0) }
    }
}

impl DaemonEnergy {
    /// The mode every periodic owner of this process watches, and that the
    /// daemon relays to acpmux (`mux/acpmux_energy.rs`).
    #[cfg_attr(not(any(test, unix)), expect(dead_code, reason = "relayed to acpmux on unix"))]
    pub(crate) fn mode(&self) -> &Arc<EnergyMode> {
        &self.mode
    }

    /// [`Self::set_app`] without "Turn Off for Now", as a v1 line sets it.
    #[cfg(test)]
    pub(crate) fn set_override(
        &self,
        client: u64,
        saver: Option<bool>,
        reason: Option<SaverReason>,
    ) -> bool {
        self.set_app(client, saver, reason, None)
    }

    /// Sets the override of control client `client` (`None` clears it,
    /// whoever set it). It holds until it is cleared or replaced, or until
    /// `client` leaves ([`Self::client_left`]). With `off_for_now`, also
    /// sets "Turn Off for Now", which outlives `client`: the daemon's own
    /// reading keeps it until the battery -> AC edge or the app's next word.
    /// Returns whether the mode changed.
    pub(crate) fn set_app(
        &self,
        client: u64,
        saver: Option<bool>,
        reason: Option<SaverReason>,
        off_for_now: Option<bool>,
    ) -> bool {
        self.store(|state| {
            let mut inputs = Inputs::unpack(state);
            inputs.app_override = saver;
            inputs.reason = reason;
            inputs.off_for_now = off_for_now.unwrap_or(inputs.off_for_now);
            let setter = if saver.is_some() { setter(client) } else { 0 };
            Some(setter | inputs.pack())
        })
    }

    /// Control client `client` left: the override it set goes with it, so
    /// the daemon follows its own reading again. Another client's override
    /// stays, and so do the setting and "Turn Off for Now". Returns whether
    /// the mode changed.
    pub fn client_left(&self, client: u64) -> bool {
        self.store(|state| {
            let mut inputs = Inputs::unpack(state);
            let holds = inputs.app_override.is_some() && state & !INPUTS == setter(client);
            holds.then(|| {
                inputs.app_override = None;
                inputs.pack()
            })
        })
    }

    /// Sets `energy.saver` as the settings owner read it (mux/settings.rs).
    /// Returns whether the mode changed.
    pub(crate) fn set_setting(&self, setting: SaverSetting) -> bool {
        self.store(|state| {
            let mut inputs = Inputs::unpack(state);
            inputs.setting = Some(setting);
            Some((state & !INPUTS) | inputs.pack())
        })
    }

    /// Sets the power facts (mux/power_source.rs). The battery -> AC edge
    /// ends "Turn Off for Now", as the app's resolver does. Returns whether
    /// the mode changed.
    pub(crate) fn set_facts(&self, facts: PowerFacts) -> bool {
        self.store(|state| {
            let mut inputs = Inputs::unpack(state);
            if inputs.facts.is_some_and(|before| before.on_battery) && !facts.on_battery {
                inputs.off_for_now = false;
            }
            inputs.facts = Some(facts);
            Some((state & !INPUTS) | inputs.pack())
        })
    }

    /// The mode, its source and every input now.
    pub fn status(&self) -> EnergyStatus {
        let inputs = Inputs::unpack(self.state.load(Ordering::Acquire));
        let reading = inputs.reading();
        let (saver, reason, source) = match inputs.app_override {
            Some(saver) => (saver, inputs.reason.filter(|_| saver), EnergySource::App),
            None => (reading.is_some(), reading, EnergySource::Daemon),
        };
        EnergyStatus {
            saver,
            source,
            reason,
            app_override: inputs.app_override,
            reading: reading.is_some(),
            setting: inputs.setting,
            off_for_now: inputs.off_for_now,
        }
    }

    /// Stores `change(state)` (nothing when it is `None`) and flips the mode
    /// to what the inputs resolve to. A writer that raced this one may have
    /// flipped the mode from older inputs after this store, so each writer
    /// flips again until the mode matches the inputs it reads last: the last
    /// store always wins.
    fn store(&self, change: impl Fn(u64) -> Option<u64>) -> bool {
        if self.state.fetch_update(Ordering::AcqRel, Ordering::Acquire, change).is_err() {
            return false;
        }
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
    /// "Turn Off for Now" holds ([`RULE_CAPABILITY`]); absent leaves it.
    #[serde(default, rename = "offForNow")]
    off_for_now: Option<bool>,
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
        set(mux, client, local && origin_gate::is_user(mux, client), fields)
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

fn set(
    mux: &Mux,
    client: u64,
    trusted: bool,
    fields: Map<String, Value>,
) -> Result<Value, &'static str> {
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
    let changed = mux.energy.set_app(client, request.saver, request.reason, request.off_for_now);
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
