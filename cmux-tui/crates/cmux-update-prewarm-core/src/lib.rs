//! The staged-update pre-warm record of the cmux macOS app: the rules of
//! the app's `StagedUpdatePrewarm` marker, in Rust, asked over the app FFI
//! (`include/cmux_update_prewarm.h`, linked through cmux-app-ffi). No I/O:
//! the app reads and writes the file.
//!
//! Why it exists (measured on a fleet Mac, 2026-11-16): a new copy of the
//! app, which each nightly update is, pays about 2 s in syspolicyd on the
//! first exec of its main executable. Running that executable once at the
//! staging path (`--cmux-prewarm-launch`, which exits at the top of main)
//! pays it ahead, and Sparkle's rename into place keeps it (a copy would
//! not). The pre-warm then runs `bin/cmux`, `cmux-tui --version` and each
//! Chromium Helper's `--version`, 5-7 s in all.
//!
//! The marker (`~/Library/Application Support/<bundle id>/launch-prewarm`)
//! used to hold only `<build>\n`, written after the whole sequence. A
//! Restart click seconds after staging cut the sequence before it, so a warm
//! launch read as cold, and a cold launch never said why. So each step now
//! writes one line, `<build> <state>[ <reason>]\n`: `started` before the
//! first exec, `main` once the main executable ran (the 2 s that matter),
//! `full` at the end, or `skipped <reason>` when it does not run. The
//! build's first launch reads it with [`launch_verdict`].
//!
//! [`ops::call`] is the one JSON entry point.

pub mod ffi;
pub mod ops;

use serde::Serialize;

/// The longest skip reason a marker keeps, in characters.
pub const MAX_REASON: usize = 200;

/// How far a staged build's pre-warm got.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarkerState {
    /// Written before the first exec; still there means it was cut.
    Started,
    /// The main executable ran: syspolicyd's first-exec cost is paid.
    Main,
    /// Every step ran.
    Full,
    /// The pre-warm did not run, and why.
    Skipped(String),
}

impl MarkerState {
    fn word(&self) -> &'static str {
        match self {
            Self::Started => "started",
            Self::Main => "main",
            Self::Full => "full",
            Self::Skipped(_) => "skipped",
        }
    }
}

/// One marker file's record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Marker {
    pub build: String,
    pub state: MarkerState,
    /// The old `<build>\n` form, written only after the whole sequence.
    pub legacy: bool,
}

/// The marker line for `build` in `state`, or none for a build that would
/// not read back (empty, or with whitespace). A skip reason is kept on one
/// line: control characters (newlines among them) become spaces, the ends
/// are trimmed and it is cut at [`MAX_REASON`] characters.
pub fn encode_marker(build: &str, state: &MarkerState) -> Option<String> {
    if build.is_empty() || build.chars().any(char::is_whitespace) {
        return None;
    }
    let mut line = format!("{build} {}", state.word());
    if let MarkerState::Skipped(reason) = state {
        let reason = one_line(reason);
        if !reason.is_empty() {
            line.push(' ');
            line.push_str(&reason);
        }
    }
    line.push('\n');
    Some(line)
}

fn one_line(reason: &str) -> String {
    let flat: String = reason.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let cut: String = flat.trim().chars().take(MAX_REASON).collect();
    cut.trim_end().to_owned()
}

/// The record in a marker file's text: the line form, or the legacy
/// `<build>\n` (a full run). None for an empty file or an unknown state, so
/// a marker from a newer app reads as no record rather than a wrong one.
pub fn parse_marker(text: &str) -> Option<Marker> {
    let line = text.lines().next()?.trim();
    if line.is_empty() {
        return None;
    }
    let Some((build, rest)) = line.split_once(char::is_whitespace) else {
        return Some(Marker { build: line.to_owned(), state: MarkerState::Full, legacy: true });
    };
    let rest = rest.trim_start();
    let (word, reason) = rest.split_once(' ').unwrap_or((rest, ""));
    let state = match (word, reason) {
        ("started", "") => MarkerState::Started,
        ("main", "") => MarkerState::Main,
        ("full", "") => MarkerState::Full,
        ("skipped", reason) => MarkerState::Skipped(reason.trim().to_owned()),
        _ => return None,
    };
    Some(Marker { build: build.to_owned(), state, legacy: false })
}

/// What a launch of `build` records about its pre-warm.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Verdict {
    /// The main executable ran ahead, so this launch skipped syspolicyd's 2 s.
    pub pre_warmed: bool,
    /// Why, for launch-times.jsonl: `no_build`, `no_record`, `other_build:<b>`,
    /// `started_not_finished`, `main`, `full`, `full_legacy` or `skipped:<reason>`.
    pub reason: String,
    /// Delete the marker: it was this build's and is now spent.
    pub consume: bool,
}

/// The verdict of `build`'s launch on the marker file's text (none when
/// there is no file). Another build's marker stays: it is a staged update
/// not installed yet.
pub fn launch_verdict(build: &str, marker_text: Option<&str>) -> Verdict {
    let verdict = |pre_warmed, reason: &str, consume| Verdict {
        pre_warmed,
        reason: reason.to_owned(),
        consume,
    };
    if build.is_empty() {
        return verdict(false, "no_build", false);
    }
    let Some(marker) = marker_text.and_then(parse_marker) else {
        return verdict(false, "no_record", false);
    };
    if marker.build != build {
        return verdict(false, &format!("other_build:{}", marker.build), false);
    }
    match marker.state {
        MarkerState::Started => verdict(false, "started_not_finished", true),
        MarkerState::Main => verdict(true, "main", true),
        MarkerState::Full if marker.legacy => verdict(true, "full_legacy", true),
        MarkerState::Full => verdict(true, "full", true),
        MarkerState::Skipped(reason) => verdict(false, &format!("skipped:{reason}"), true),
    }
}
