//! The plain words a person reads: a part's `detail` and a receipt's.
//!
//! No ids, no pids, no jargon; the part's name is its `label` (from
//! `register`), shown next to the detail by the UI, so the words here never
//! repeat it. Sizes are decimal (1 GB = 10^9 bytes), as the macOS Finder
//! counts.

use crate::{Kind, RepairAction};

/// Why a part is not healthy, with the numbers its words need.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Cause {
    #[default]
    Healthy,
    PageSilent {
        ms: u64,
    },
    PageInput {
        ms: u64,
    },
    PageCrashed,
    RendererUnresponsive {
        ms: u64,
    },
    RendererCrashed,
    AcpmuxDisconnected,
    AcpmuxSilent {
        ms: u64,
    },
    HostListenerMissing,
    HostLoadFailed,
    DaemonLoop {
        starts: usize,
        span_ms: u64,
    },
    DaemonRestoring {
        bytes: u64,
        /// The workspace data on disk (`size`), 0 when unknown: the percent's denominator.
        total: u64,
    },
    DaemonStalled {
        bytes: u64,
        ms: u64,
    },
    DaemonOversize {
        bytes: u64,
    },
    RosterSlow {
        ms: u64,
    },
    RosterStuck {
        ms: u64,
    },
}

/// `bytes` with one decimal and no trailing `.0`: "12.4 GB", "59 GB".
pub fn human_bytes(bytes: u64) -> String {
    const UNITS: &[&str] = &["KB", "MB", "GB", "TB", "PB"];
    if bytes < 1_000 {
        return format!("{bytes} bytes");
    }
    let mut value = bytes as f64 / 1_000.0;
    let mut unit = 0;
    while value >= 999.95 && unit + 1 < UNITS.len() {
        value /= 1_000.0;
        unit += 1;
    }
    let text = format!("{value:.1}");
    let text = text.strip_suffix(".0").unwrap_or(&text);
    format!("{text} {}", UNITS.get(unit).copied().unwrap_or("PB"))
}

/// Whole units: "59 GB" (a size the user compares, not a counter).
fn whole_bytes(bytes: u64) -> String {
    let gb = (bytes as f64 / 1e9).round() as u64;
    if gb >= 1 { format!("{gb} GB") } else { human_bytes(bytes) }
}

/// "12 s", "6 min".
pub fn duration(ms: u64) -> String {
    let secs = ms / 1_000;
    if secs < 120 { format!("{secs} s") } else { format!("{} min", (secs + 30) / 60) }
}

/// The cause alone, a full sentence.
pub fn cause(cause: Cause) -> String {
    match cause {
        Cause::Healthy => String::new(),
        Cause::PageSilent { ms } => format!("Not answering for {}.", duration(ms)),
        Cause::PageInput { ms } => {
            format!("Has not handled your clicks or typing for {}.", duration(ms))
        }
        Cause::PageCrashed | Cause::RendererCrashed => "Stopped unexpectedly.".into(),
        Cause::RendererUnresponsive { ms } => format!("Not responding for {}.", duration(ms)),
        Cause::AcpmuxDisconnected => "Agent sessions are disconnected.".into(),
        Cause::AcpmuxSilent { ms } => {
            format!("Agent sessions have not answered for {}.", duration(ms))
        }
        Cause::HostListenerMissing => "Pages cannot load: their server is not running.".into(),
        Cause::HostLoadFailed => "Pages keep failing to load.".into(),
        Cause::DaemonLoop { starts, span_ms } => format!(
            "The session service restarted {starts} times in {} without finishing startup. \
             Holding restarts so the current one can finish restoring.",
            duration(span_ms)
        ),
        // Read over size only estimates how far a restore got (it rereads some pages and skips others),
        // so it says "about" and caps at 99: never done before ready.
        Cause::DaemonRestoring { bytes: 0, .. } => "Restoring workspaces".into(),
        Cause::DaemonRestoring { bytes, total } if total > 0 => {
            format!("Restoring workspaces, about {}%", (bytes.saturating_mul(100) / total).min(99))
        }
        Cause::DaemonRestoring { bytes, .. } => {
            format!("Restoring workspaces, {} read", human_bytes(bytes))
        }
        Cause::DaemonStalled { bytes, ms } => format!(
            "Restoring workspaces has made no progress for {} ({} read). Waiting; a restore is \
             never interrupted.",
            duration(ms),
            human_bytes(bytes)
        ),
        Cause::DaemonOversize { bytes } => {
            format!("Workspace data is {}; startup will be slow", whole_bytes(bytes))
        }
        Cause::RosterSlow { ms } => format!("Restoring workspaces is taking {}.", duration(ms)),
        Cause::RosterStuck { ms } => {
            format!("Restoring workspaces has run for {} without finishing.", duration(ms))
        }
    }
}

/// What a repair does, in words.
fn doing(action: RepairAction) -> &'static str {
    match action {
        RepairAction::ReloadPage => "Reloading it",
        RepairAction::RestartRenderer => "Restarting it",
        RepairAction::Reconnect => "Reconnecting",
        RepairAction::RestartConnection => "Restarting the connection",
        RepairAction::RestartPageHost => "Restarting the page server",
        RepairAction::HoldReplace => "Holding restarts",
        RepairAction::None => "Waiting",
    }
}

/// A page keeps its draft through every repair; say so.
fn kept(kind: Kind) -> &'static str {
    if kind == Kind::Page { "; your draft is kept" } else { "" }
}

/// A part a repair is out for: "Not answering for 12 s. Reloading it
/// (attempt 1 of 3); your draft is kept."
pub fn repairing(kind: Kind, why: Cause, action: RepairAction, attempt: u32, max: u32) -> String {
    format!("{} {} (attempt {attempt} of {max}){}.", cause(why), doing(action), kept(kind))
}

/// A part whose repairs ran out.
pub fn failed(kind: Kind, why: Cause, max: u32) -> String {
    format!("{} Tried {max} repairs without luck; click to try again{}.", cause(why), kept(kind))
}

/// The receipt of an attempt sent to the host.
pub fn receipt_started(kind: Kind, action: RepairAction, attempt: u32, max: u32) -> String {
    if action == RepairAction::HoldReplace {
        return "Asked the launcher to let the current session service finish starting.".into();
    }
    format!("{} (attempt {attempt} of {max}){}.", doing(action), kept(kind))
}

/// The receipt of the host's result.
pub fn receipt_result(ok: bool) -> String {
    if ok {
        "Done; waiting for it to answer again.".into()
    } else {
        "That repair did not work; trying the next one.".into()
    }
}

/// The receipt of a part whose signal came back after repairs.
pub fn receipt_recovered(kind: Kind) -> String {
    match kind {
        Kind::Page | Kind::Renderer => "Answering again.".into(),
        Kind::Acpmux => "Agent sessions answer again.".into(),
        Kind::PageHost => "Pages load again.".into(),
        Kind::SessionDaemon | Kind::Roster => "Working again.".into(),
    }
}

/// The receipt of a part that gave up.
pub fn receipt_gave_up(max: u32) -> String {
    format!("Gave up after {max} repairs; waiting for you to try again.")
}
