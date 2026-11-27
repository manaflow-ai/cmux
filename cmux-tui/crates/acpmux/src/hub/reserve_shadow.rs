//! Auto on reserve in shadow (RFD 0072 stage 1, "Shadow": the trigger runs and writes what it
//! would move and why; nothing moves). Each `daemon status` `host_pressure` read feeds the host
//! budget's [`ReserveTracker`] one sample: the meter's last readings (`Meter::last_sample`), its
//! verdict, this computer's RAM and the agents' own use (piece 2, `session_usage.rs`). The
//! verdict is published as `host_pressure.reserve` and every move or return is appended to
//! `auto-shadow.jsonl` ([`shadow_log_path`]); the app's Auto reads `reserve.out` as its Busy
//! shadow signal (`cmux-cloud-start-core` `place::verdict`). Nothing here moves a chat.
//!
//! The tracker judges whatever the person's `cloud.auto` says (shadow is how the rule earns the
//! switch); the published object carries that setting as `enabled`, and `acts` stays false.

use crate::host_pressure::reserve::{
    AgentUse, DEFAULT_RESERVE_PERCENT, ReserveReason, ReserveSample, ReserveSetting,
    ReserveTracker, ReserveVerdict, ShadowLine, append_shadow, shadow_log_path,
};
use crate::host_pressure::{Sample, Verdict};
use crate::hub::session_usage::AgentsUsage;
use crate::user_settings::{self, Settings};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Mutex;

/// The setting that turns Auto on reserve on (off by default).
pub(crate) const AUTO_KEY: &str = "cloud.auto";
/// The share of this computer the person keeps for themselves (`RESERVE_STOPS`).
pub(crate) const RESERVE_KEY: &str = "cloud.autoReservePercent";

/// The rule's input from what the daemon reads, or `None` without the RAM size or a sample.
///
/// Every agent counts as movable: shadow names the heaviest agent, and the app's own gates (the
/// front chat, a chat pinned local, one with no Cloud) apply when it reads `reserve.out`.
pub(crate) fn reserve_sample(
    at_ms: u64,
    sample: Option<&Sample>,
    verdict: Option<&Verdict>,
    ram_total: Option<u64>,
    agents: &AgentsUsage,
) -> Option<ReserveSample> {
    let sample = sample?;
    let ram_bytes = ram_total.filter(|&b| b > 0)?;
    let cores = sample.performance_cores.or(sample.physical_cores).unwrap_or(sample.logical_cpus);
    if cores == 0 {
        return None;
    }
    let pressure = verdict.map(|v| v.pressure);
    Some(ReserveSample {
        at_ms,
        performance_cores: f64::from(cores),
        ram_bytes,
        idle_ms: sample.hid_idle_seconds.filter(|s| *s >= 0.0).map(|s| (s * 1000.0) as u64),
        memory_normal: !matches!(pressure, Some("warn" | "critical")),
        cpu_busy: sample.cpu_busy,
        lateness_p50_ms: sample.lateness_p50_ms,
        slow_frames: false,
        swap_growth_mb_per_min: verdict.and_then(|v| v.swap_mb_per_min),
        used_ram_bytes: sample
            .available_ram_fraction
            .map(|free| (ram_bytes as f64 * (1.0 - free.clamp(0.0, 1.0))) as u64),
        thermal_serious: sample.thermal_pressure_level.is_some_and(|l| l >= 2),
        agents: agents
            .sessions
            .iter()
            .map(|s| AgentUse {
                session: s.id.clone(),
                cpu_cores: s.load.cpu_cores,
                rss_bytes: s.load.rss_bytes,
                in_turn: s.load.active,
                movable: true,
            })
            .collect(),
    })
}

/// The person's setting: `cloud.auto` (off unless `true`) and `cloud.autoReservePercent`.
pub(crate) fn setting_from(settings: &Settings) -> ReserveSetting {
    let doc = match settings {
        Settings::Parsed(doc) => Some(doc),
        Settings::Missing | Settings::Unreadable(_) => None,
    };
    let read = |key| doc.and_then(|d| user_settings::value(d, key));
    ReserveSetting {
        enabled: read(AUTO_KEY).and_then(|v| v.as_bool()).unwrap_or(false),
        reserve_percent: read(RESERVE_KEY)
            .and_then(|v| v.as_u64())
            .and_then(|p| u8::try_from(p).ok())
            .unwrap_or(DEFAULT_RESERVE_PERCENT),
    }
}

/// The tracker and, for each session it holds moved out, why and since when.
#[derive(Default)]
pub(crate) struct Shadow {
    tracker: ReserveTracker,
    out: BTreeMap<String, (ReserveReason, u64)>,
}

impl Shadow {
    /// Judges one sample in shadow (the rule on, at the person's reserve) and returns
    /// `host_pressure.reserve`; a move or a return goes to `log` too.
    pub(crate) fn judge(&mut self, person: ReserveSetting, sample: &ReserveSample, log: Option<&Path>) -> Value {
        let setting = ReserveSetting { enabled: true, ..person };
        let verdict = self.tracker.judge(&setting, sample);
        match &verdict {
            ReserveVerdict::MoveOut { session, reason } => {
                self.out.insert(session.clone(), (*reason, sample.at_ms));
            }
            ReserveVerdict::BringBack { session, .. } => {
                self.out.remove(session);
            }
            ReserveVerdict::Hold { .. } => {}
        }
        let moved: std::collections::BTreeSet<&str> = self.tracker.moved().collect();
        self.out.retain(|s, _| moved.contains(s.as_str()));
        let line = ShadowLine::new(&setting, sample, verdict);
        if let Some(path) = log {
            // Best effort: a full disk or a read-only state dir loses a line, never the status.
            let _ = append_shadow(path, &line);
        }
        let mut v = serde_json::to_value(&line).unwrap_or_else(|_| json!({}));
        if let Some(obj) = v.as_object_mut() {
            obj.insert("enabled".into(), json!(person.enabled));
            obj.insert("acts".into(), json!(false));
            let out: Vec<Value> = self
                .out
                .iter()
                .map(|(session, (reason, at))| json!({"session": session, "reason": reason, "atMs": at}))
                .collect();
            obj.insert("out".into(), Value::Array(out));
        }
        v
    }
}

static SHADOW: Mutex<Option<Shadow>> = Mutex::new(None);

/// `host_pressure.reserve` for this daemon now, or `None` when the rule has nothing to read
/// (no sample yet, no RAM size). Blocking: reads the settings file and appends to the log.
pub(crate) fn judge_now(
    at_ms: u64,
    sample: Option<&Sample>,
    verdict: Option<&Verdict>,
    agents: &AgentsUsage,
) -> Option<Value> {
    let ram = crate::server::peer_status::ram_total();
    let input = reserve_sample(at_ms, sample, verdict, ram, agents)?;
    let person = setting_from(&user_settings::read());
    let log = shadow_log_path(Some(&crate::config::home()));
    let mut shadow = SHADOW.lock().unwrap_or_else(|e| e.into_inner());
    Some(shadow.get_or_insert_with(Shadow::default).judge(person, &input, log.as_deref()))
}

#[cfg(test)]
#[path = "reserve_shadow_tests.rs"]
mod tests;
