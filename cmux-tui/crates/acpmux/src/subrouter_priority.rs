//! The subrouter priority of a Claude Code session: `X-Subrouter-Priority:
//! interactive` or `background` on every model request, so the gateways keep
//! a reserved share of accounts and call slots for the chats Leo talks to
//! ("I can't even talk to the GUI chats right now because of alleged
//! overload", 2026-11-23). Interactive: a chat the person made (the app, the
//! phone) and a coordinator (`claude-sr2-coord`, `interim-coord`, any name
//! ending in `-coord`, or `-coord-old`), and a priority lane: a dictator (a
//! name containing `dictator`, e.g. `ci-217x-dictator`, whose merges stalled
//! 14:27Z-17:01Z on 2026-11-23 gateway 503s) or an ask lane (a name starting
//! `ask-`). Lanes a coordinator starts stay background: that is nearly every
//! lane, and a reserve everyone holds reserves nothing. Everything else acpmux launches
//! (lanes, helpers, subagents, relays, scripts) is background.
//!
//! The hub decides at spawn ([`profile_with`], from what the session records)
//! and puts [`ENV`] into the profile's env; the launch turns it into the
//! header line in `ANTHROPIC_CUSTOM_HEADERS` ([`custom_headers`]), after any
//! lines already there. A value a profile or login set itself wins.

use crate::subrouter_session::HEADERS_ENV;

/// `interactive` or `background`: the priority this process's requests carry.
/// A profile may also name one of subrouter's other classes, `coordinator` or
/// `batch` (subrouter-internal `internal/proxy/admission_class.go`; the
/// gateway finds a `/compact` from the request body itself).
pub const ENV: &str = "SUBROUTER_PRIORITY";
const HEADER: &str = "X-Subrouter-Priority";
pub const INTERACTIVE: &str = "interactive";
pub const BACKGROUND: &str = "background";

/// Whether `value` (lowercase) is a priority [`ENV`] may carry.
pub fn is_known(value: &str) -> bool {
    matches!(value, INTERACTIVE | BACKGROUND | "coordinator" | "batch")
}

/// Whether `name` is a coordinator session's name.
pub fn is_coordinator(name: &str) -> bool {
    let name = name.trim().to_ascii_lowercase();
    name == "interim-coord" || name.ends_with("-coord") || name.ends_with("-coord-old")
}

/// Whether `name` is a priority lane that keeps the interactive share: a
/// dictator or an ask lane.
pub fn is_priority_lane(name: &str) -> bool {
    let name = name.trim().to_ascii_lowercase();
    name.contains("dictator") || name.starts_with("ask-")
}

/// The priority of a session named `name`; `for_person`: the person made it
/// (`host_level::made_for_a_person`).
pub fn classify(name: &str, for_person: bool) -> &'static str {
    if for_person || is_coordinator(name) || is_priority_lane(name) {
        INTERACTIVE
    } else {
        BACKGROUND
    }
}

/// The session tag that sets a session's priority by hand: `interactive` or `background`.
pub const TAG: &str = "priority";

/// Whether a session's role makes it a coordinator, whatever its name.
///
/// On 2026-11-24 at 21:1xZ the interim coordinator's `/compact` failed with "503 no
/// non-exhausted claude accounts available; next account frees up in 29m". The interim
/// coordinator runs as `cosmic-gray/interim-coord-2`, and its deputies as `coord-deputy*`,
/// `coord-successor` and `coord-dispatcher`. None of them matched [`is_coordinator`]'s names, so
/// they were sent as background, and the gateway's interactive reserve
/// (subrouter-internal#85) held nothing back for them. A role is now read from what the
/// session is: `leads` (live sessions report to it through `lane.reportsTo`, as `acpmux ls
/// --leads` derives a leader), an `interim-` name (each interim coordinator's generated name)
/// or `chief`. The tag [`TAG`] overrides all of it.
pub fn classify_role(
    name: &str,
    for_person: bool,
    leads: usize,
    tag: Option<&str>,
) -> &'static str {
    match tag.map(|t| t.trim().to_ascii_lowercase()).as_deref() {
        Some(INTERACTIVE) => return INTERACTIVE,
        Some(BACKGROUND) => return BACKGROUND,
        _ => {}
    }
    // A sub-session's name carries its parent's (`coord-successor/ws-disk`): only its own
    // last segment names its role.
    let own = name.rsplit('/').next().unwrap_or(name).trim().to_ascii_lowercase();
    if leads > 0 || own.starts_with("interim-") || own == "chief" || own.starts_with("chief-") {
        return INTERACTIVE;
    }
    classify(&own, for_person)
}

/// `profile` with [`ENV`] set to this session's priority, unless the profile
/// names one itself.
pub fn profile_with(
    profile: &crate::config::HarnessProfile,
    priority: &'static str,
) -> crate::config::HarnessProfile {
    let mut profile = profile.clone();
    profile.env.entry(ENV.to_owned()).or_insert_with(|| priority.to_owned());
    profile
}

/// [`ENV`] in a profile's `env`, unless it names one already.
pub fn set(env: &mut std::collections::BTreeMap<String, String>, name: &str, for_person: bool) {
    env.entry(ENV.to_owned()).or_insert_with(|| classify(name, for_person).to_owned());
}

/// The `ANTHROPIC_CUSTOM_HEADERS` value for a process whose final env is
/// `get`: the existing lines (an older priority line dropped) plus this
/// one, or `None` when [`ENV`] is unset or not a known priority.
pub fn custom_headers(get: impl Fn(&str) -> Option<String>) -> Option<String> {
    let priority = get(ENV)?.trim().to_ascii_lowercase();
    if !is_known(&priority) {
        return None;
    }
    let mut lines: Vec<String> = get(HEADERS_ENV)
        .unwrap_or_default()
        .lines()
        .filter(|l| {
            let name = l.split(':').next().unwrap_or("").trim();
            !l.trim().is_empty() && !name.eq_ignore_ascii_case(HEADER)
        })
        .map(str::to_owned)
        .collect();
    lines.push(format!("{HEADER}: {priority}"));
    Some(lines.join("\n"))
}

#[cfg(test)]
#[path = "subrouter_priority_tests.rs"]
mod tests;
