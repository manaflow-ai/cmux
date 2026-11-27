//! Which hidden pages are discarded now, and when to look again; which freeze.

use crate::setting::{Mode, Setting};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

/// The system's memory pressure (the app's `MemoryPressureLevel`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Pressure {
    #[default]
    Normal,
    Warning,
    Critical,
}

/// One hidden page that could freeze or be discarded: what the app knows of it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Candidate {
    pub key: String,
    /// Seconds since the page was last visible.
    pub hidden_for: f64,
    pub host: Option<String>,
    pub is_pinned: bool,
    pub has_dev_tools: bool,
    /// Camera or microphone in use (Page Info); the probe finds the rest.
    pub is_capturing: bool,
    /// The engine can save and restore its history.
    pub can_restore: bool,
    /// The shown document came from a POST (BR-R1).
    pub shows_form_submission: bool,
    /// Times the person showed the tab in the last hour.
    pub recent_focus_count: i64,
    /// The page's memory (its renderers' footprint, shared ones split), when sampled.
    pub memory_bytes: Option<u64>,
    /// A download the page started still runs.
    pub is_downloading: bool,
    /// An agent holds the page's browser lease.
    pub has_agent_lease: bool,
    /// The probe kept the page lately (it played or held form input): under pressure it ranks
    /// after the others, so it does not hold up the relief of the rest.
    pub recently_kept: bool,
    /// The page's site may show notifications: the timeout keeps it, memory pressure does not
    /// (Chrome's kNotificationsEnabled, proactive discards only).
    pub allows_notifications: bool,
}

impl Default for Candidate {
    fn default() -> Self {
        Candidate {
            key: String::new(),
            hidden_for: 0.0,
            host: None,
            is_pinned: false,
            has_dev_tools: false,
            is_capturing: false,
            can_restore: true,
            shows_form_submission: false,
            recent_focus_count: 0,
            memory_bytes: None,
            is_downloading: false,
            has_agent_lease: false,
            recently_kept: false,
            allows_notifications: false,
        }
    }
}

/// Why a page is not discarded (reported by the app's `debug.surfaces`). The app adds its own
/// (`neighbor`, `agent_driving`, `agent_busy`, ...); the ones the rules here give are below.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Exemption {
    Disabled,
    Excluded,
    Pinned,
    #[serde(rename = "devtools")]
    DevTools,
    Capturing,
    Unsupported,
    /// The probe heard it play (an element, Picture in Picture).
    Audio,
    /// The person's edits in a field.
    FormInput,
    /// A running Web Audio context.
    WebAudio,
    /// The page would ask before it unloads.
    BeforeUnload,
    #[serde(rename = "web_rtc")]
    WebRtc,
    ConnectedDevice,
    /// The person moved into a child frame whose fields cannot be read.
    UnreadableFrame,
    /// The page's site may show notifications; kept from the timeout, not from memory pressure.
    Notifications,
    /// The page shows a form result (BR-R1).
    FormSubmission,
    /// The page did not answer the probe and still gets the benefit of the doubt.
    Unanswered,
    Downloading,
    AgentLease,
    /// The setting only freezes hidden pages: they keep their state and are never discarded on
    /// their own ([`Setting::discards_automatically`]).
    KeepsState,
}

/// How many pages one pass discards and how soon the next pass runs while more are due, so pages
/// never all close at once.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct Pace {
    pub per_pass: usize,
    pub interval: f64,
    /// Pages hidden less than this never go (the person just left them).
    pub minimum_hidden: f64,
}

impl Pace {
    pub const NORMAL: Pace = Pace { per_pass: 2, interval: 5.0, minimum_hidden: 0.0 };
    pub const WARNING: Pace = Pace { per_pass: 1, interval: 15.0, minimum_hidden: 60.0 };
    pub const CRITICAL: Pace = Pace { per_pass: 3, interval: 3.0, minimum_hidden: 10.0 };

    pub fn at(pressure: Pressure) -> Pace {
        match pressure {
            Pressure::Normal => Pace::NORMAL,
            Pressure::Warning => Pace::WARNING,
            Pressure::Critical => Pace::CRITICAL,
        }
    }
}

/// The result of a pass.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Plan {
    /// Keys to discard now (after the probe), or to freeze.
    pub due: Vec<String>,
    /// Seconds until the next page reaches its deadline; `None` when none will.
    pub next_check: Option<f64>,
    pub exemptions: BTreeMap<String, Exemption>,
}

/// Seconds hidden before a page is discarded; `None` means never.
pub fn threshold(setting: &Setting, pressure: Pressure) -> Option<f64> {
    let mode = setting.effective_mode();
    let minutes = mode.hidden_minutes()?;
    Some(match pressure {
        Pressure::Normal => minutes * 60.0,
        Pressure::Warning if mode == Mode::Aggressive => 0.0,
        Pressure::Warning => minutes.min(10.0) * 60.0,
        Pressure::Critical => 0.0,
    })
}

/// Why `candidate` is never discarded by the timeout or pressure, before its page is asked.
pub fn exemption(candidate: &Candidate, setting: &Setting) -> Option<Exemption> {
    if !setting.is_enabled() {
        return Some(Exemption::Disabled);
    }
    if !candidate.can_restore {
        return Some(Exemption::Unsupported);
    }
    if candidate.has_agent_lease {
        return Some(Exemption::AgentLease);
    }
    if candidate.is_downloading {
        return Some(Exemption::Downloading);
    }
    if candidate.shows_form_submission {
        return Some(Exemption::FormSubmission);
    }
    if candidate.has_dev_tools {
        return Some(Exemption::DevTools);
    }
    if candidate.is_capturing {
        return Some(Exemption::Capturing);
    }
    if candidate.is_pinned && !setting.includes_pinned_tabs {
        return Some(Exemption::Pinned);
    }
    if setting.excludes(candidate.host.as_deref()) {
        return Some(Exemption::Excluded);
    }
    None
}

/// Which hidden pages freeze now, and when the next one will: after `freeze_seconds` hidden,
/// whatever the hibernation mode, except pinned tabs (unless they hibernate too), excluded hosts,
/// open DevTools, capture and an agent's lease.
pub fn freeze_plan(setting: &Setting, candidates: &[Candidate]) -> Plan {
    let mut plan = Plan::default();
    let Some(threshold) = setting.freeze_seconds else { return plan };
    for candidate in candidates {
        if candidate.has_dev_tools
            || candidate.is_capturing
            || candidate.has_agent_lease
            || setting.excludes(candidate.host.as_deref())
            || (candidate.is_pinned && !setting.includes_pinned_tabs)
        {
            continue;
        }
        let remaining = threshold - candidate.hidden_for;
        if remaining <= 0.0 {
            plan.due.push(candidate.key.clone());
        } else {
            plan.next_check = Some(plan.next_check.map_or(remaining, |next| next.min(remaining)));
        }
    }
    plan
}

/// The share of the timeout each doubling of recent focus buys: at the 30 minute default a tab
/// shown 15 times in the last hour (4 doublings) is discarded 20 minutes later than one never
/// shown. A share, not a fixed time, so a short timeout stays short.
pub const FOCUS_CREDIT_PER_DOUBLING: f64 = 1.0 / 6.0;

/// Seconds a page's memory counts as extra idleness under memory pressure: one minute per
/// 100 MB, at most 10.
pub fn memory_credit(bytes: Option<u64>) -> f64 {
    let Some(bytes) = bytes else { return 0.0 };
    (bytes as f64 / (100u64 << 20) as f64).min(10.0) * 60.0
}

/// How idle a page counts as: seconds hidden, plus its memory under pressure, less its recent
/// focus (a share of `timeout`). Larger is less valuable: it goes first and sooner.
pub fn idleness(candidate: &Candidate, pressure: Pressure, timeout: f64) -> f64 {
    let focus_count = candidate.recent_focus_count.clamp(0, 63) as f64;
    let focus = (1.0 + focus_count).log2() * FOCUS_CREDIT_PER_DOUBLING * timeout;
    let memory =
        if pressure == Pressure::Normal { 0.0 } else { memory_credit(candidate.memory_bytes) };
    candidate.hidden_for + memory - focus
}

struct Ranked<'a> {
    key: &'a str,
    idleness: f64,
    hidden_for: f64,
    kept: bool,
}

/// The pages to discard now, least valuable first, and when to look again.
///
/// A page is due once its idleness reaches the timeout (10 minutes at most under pressure).
/// Under memory pressure, when no page is due, the least valuable page hidden at least
/// [`Pace::minimum_hidden`] goes anyway, to relieve it. Each pass takes at most
/// [`Pace::per_pass`] pages and looks again after [`Pace::interval`] while more are waiting.
///
/// Without [`Setting::discards_automatically`] no page is due, at any memory pressure: a
/// discarded page reloads when it wakes, which the person did not ask for.
pub fn plan(setting: &Setting, pressure: Pressure, candidates: &[Candidate]) -> Plan {
    let mut plan = Plan::default();
    if setting.is_enabled() && !setting.discards_automatically {
        for candidate in candidates {
            let reason = exemption(candidate, setting).unwrap_or(Exemption::KeepsState);
            plan.exemptions.insert(candidate.key.clone(), reason);
        }
        return plan;
    }
    let base = if pressure == Pressure::Critical { Pressure::Warning } else { pressure };
    let Some(threshold) = threshold(setting, base) else {
        for candidate in candidates {
            plan.exemptions.insert(candidate.key.clone(), Exemption::Disabled);
        }
        return plan;
    };
    let pace = Pace::at(pressure);
    let mut ranked: Vec<Ranked<'_>> = Vec::new();
    for candidate in candidates {
        if let Some(reason) = exemption(candidate, setting) {
            plan.exemptions.insert(candidate.key.clone(), reason);
            continue;
        }
        // Only memory pressure takes a page that may show notifications (Chrome: urgent discards only).
        if candidate.allows_notifications && pressure == Pressure::Normal {
            plan.exemptions.insert(candidate.key.clone(), Exemption::Notifications);
            continue;
        }
        ranked.push(Ranked {
            key: &candidate.key,
            idleness: idleness(candidate, pressure, threshold),
            hidden_for: candidate.hidden_for,
            kept: pressure != Pressure::Normal && candidate.recently_kept,
        });
    }
    ranked.sort_by(|a, b| {
        a.kept
            .cmp(&b.kept)
            .then_with(|| b.idleness.total_cmp(&a.idleness))
            .then_with(|| a.key.cmp(b.key))
    });
    // A page the person just left never goes, whatever its memory or the mode.
    let old_enough: Vec<&Ranked<'_>> =
        ranked.iter().filter(|page| page.hidden_for >= pace.minimum_hidden).collect();
    // Pages the probe just kept come last: only when no other page can go.
    let fresh: Vec<&Ranked<'_>> = old_enough.iter().copied().filter(|page| !page.kept).collect();
    let mut due: Vec<&Ranked<'_>> =
        fresh.iter().copied().filter(|page| page.idleness >= threshold).collect();
    if due.is_empty() && pressure != Pressure::Normal {
        due = fresh.clone();
    }
    if due.is_empty() {
        due = old_enough.iter().copied().filter(|page| page.idleness >= threshold).collect();
    }
    if due.is_empty() && pressure != Pressure::Normal {
        due = old_enough.clone();
    }
    plan.due = due.iter().take(pace.per_pass).map(|page| page.key.to_owned()).collect();
    if due.len() > plan.due.len() || (pressure != Pressure::Normal && !plan.due.is_empty()) {
        plan.next_check = Some(pace.interval);
    }
    let due_keys: HashSet<&str> = due.iter().map(|page| page.key).collect();
    for page in ranked.iter().filter(|page| !due_keys.contains(page.key)) {
        let young = pace.minimum_hidden - page.hidden_for;
        let mut wait = (threshold - page.idleness).max(young);
        // Under pressure any page old enough is relief: look again once this one is.
        if pressure != Pressure::Normal {
            wait = wait.min(young.max(pace.interval));
        }
        let wait = wait.max(0.001);
        plan.next_check = Some(plan.next_check.map_or(wait, |next| next.min(wait)));
    }
    plan
}
