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
pub const ENV: &str = "SUBROUTER_PRIORITY";
const HEADER: &str = "X-Subrouter-Priority";
pub const INTERACTIVE: &str = "interactive";
pub const BACKGROUND: &str = "background";

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
    if priority != INTERACTIVE && priority != BACKGROUND {
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
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn run(pairs: &[(&str, &str)]) -> Option<String> {
        let env: BTreeMap<String, String> =
            pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        custom_headers(|k| env.get(k).cloned())
    }

    #[test]
    fn person_chats_and_coordinators_are_interactive() {
        assert_eq!(classify("claude-17", true), INTERACTIVE);
        for coord in ["claude-sr2-coord", "claude-sr2-coord-old", "interim-coord", "web-coord"] {
            assert_eq!(classify(coord, false), INTERACTIVE, "{coord}");
        }
        for lane in ["ci-217x-dictator", "merge-dictator-2", "ask-efe8c0bf62", "ASK-gui-chats"] {
            assert_eq!(classify(lane, false), INTERACTIVE, "{lane}");
        }
        for lane in [
            "lane-gateway",
            "helper-3",
            "optchat-a-sub",
            "coordinator-relay",
            "coord",
            "task-ask-x",
        ] {
            assert_eq!(classify(lane, false), BACKGROUND, "{lane}");
        }
    }

    #[test]
    fn leaders_interim_coordinators_and_chief_are_interactive_by_role() {
        // The live coordinators of 2026-11-24, which the names alone left background.
        for (name, leads) in [
            ("interim-coord-2", 0),
            ("coord-successor", 3),
            ("coord-deputy-r2", 1),
            ("coord-dispatcher", 2),
            ("chief", 0),
        ] {
            assert_eq!(classify_role(name, false, leads, None), INTERACTIVE, "{name}");
        }
        // A coordinator's own lanes stay background: they lead nobody.
        for name in ["coord-successor/ws-disk", "coord-overload-inbox", "helper-3", "chief/sub"] {
            assert_eq!(classify_role(name, false, 0, None), BACKGROUND, "{name}");
        }
        // The names classify() knew still count, under a parent's prefix too.
        assert_eq!(classify_role("x/claude-sr2-coord", false, 0, None), INTERACTIVE);
        assert_eq!(classify_role("lane-3", true, 0, None), INTERACTIVE);
    }

    #[test]
    fn the_priority_tag_wins_over_the_role() {
        assert_eq!(classify_role("helper-3", false, 0, Some("Interactive")), INTERACTIVE);
        assert_eq!(classify_role("coord-successor", false, 4, Some("background")), BACKGROUND);
        assert_eq!(classify_role("helper-3", false, 0, Some("urgent")), BACKGROUND);
    }

    #[test]
    fn appends_after_existing_lines_and_replaces_an_older_priority() {
        let got = run(&[
            (ENV, "interactive"),
            (HEADERS_ENV, "X-Subrouter-Session: s1\nx-subrouter-priority: background"),
        ]);
        assert_eq!(
            got.as_deref(),
            Some("X-Subrouter-Session: s1\nX-Subrouter-Priority: interactive")
        );
        assert_eq!(
            run(&[(ENV, "background")]).as_deref(),
            Some("X-Subrouter-Priority: background")
        );
    }

    #[test]
    fn unset_or_unknown_changes_nothing() {
        assert_eq!(run(&[(HEADERS_ENV, "A: b")]), None);
        assert_eq!(run(&[(ENV, "urgent\nX-Evil: 1")]), None);
    }

    #[test]
    fn a_profile_value_wins() {
        let mut env = BTreeMap::new();
        set(&mut env, "lane-1", true);
        assert_eq!(env.get(ENV).map(String::as_str), Some(INTERACTIVE));
        let mut env = BTreeMap::from([(ENV.to_owned(), BACKGROUND.to_owned())]);
        set(&mut env, "x-coord", true);
        assert_eq!(env.get(ENV).map(String::as_str), Some(BACKGROUND));
    }
}
