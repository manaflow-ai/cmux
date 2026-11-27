//! Where new work runs (cmuxterm-hq RFD 0032 "Place", section Auto): here, or
//! spilled to another machine because this one is over its budget.
//!
//! [`decide`] is the one function: the kind of work, this host's budget level,
//! the places with room, the user's setting and an explicit override in; a
//! place and the reason for it out, as data. It is pure and knows nothing of
//! terminals, so `cmux spill` (a command) calls it now and Auto for new agent
//! sessions calls it later.
//!
//! The rules, in order:
//! 1. An override wins: `--here` runs here, `--to MACHINE` runs there.
//! 2. Work that came without being asked to spill (Auto) runs here unless the
//!    Auto setting is on and, for a command, the command matches the user's
//!    rule list (build and test commands). Off is the default.
//! 3. The trigger is the host budget's own level, with its own warn and release
//!    thresholds ([`crate::Tracker`], [`crate::level_for`]): at
//!    [`Level::Warning`] or above this host is over; a level not read is
//!    never over.
//! 4. Over budget, the work goes to the first place with room. A place whose
//!    headroom is unknown or stale is never room (RFD 0025's rule); none with
//!    room keeps the work here, and says so.
//!
//! Places are asked for only when this host is over, so a host within budget
//! pays nothing to learn about them.

use serde::Serialize;

use crate::Level;

/// What is being placed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Work<'a> {
    /// A command, as its argv.
    Command(&'a [String]),
    /// A new agent session.
    Session,
}

/// How the work reached the decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Asked {
    /// The person ran it through the spill verb: they offered it to spill.
    Spill,
    /// It started on its own (a command typed in a terminal, a new session):
    /// it spills only when the Auto setting says so.
    Auto,
}

/// The user's setting: Auto on or off, and the commands Auto may spill.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Setting {
    pub auto: bool,
    /// Each rule is the words a command starts with (`cargo test`, `make`);
    /// the first word is compared by its file name (`/usr/bin/make` is `make`).
    pub rules: Vec<String>,
}

impl Default for Setting {
    fn default() -> Self {
        Self { auto: false, rules: DEFAULT_RULES.iter().map(|r| (*r).to_owned()).collect() }
    }
}

/// The build and test commands Auto spills when no list is given.
pub const DEFAULT_RULES: &[&str] = &[
    "cargo build",
    "cargo test",
    "cargo check",
    "cargo clippy",
    "cargo nextest",
    "make",
    "ninja",
    "cmake --build",
    "go build",
    "go test",
    "swift build",
    "swift test",
    "npm test",
    "npm run build",
    "pnpm test",
    "pnpm build",
    "bun test",
    "pytest",
];

/// An explicit choice that skips the budget.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Override {
    #[default]
    None,
    /// `--here`.
    Here,
    /// `--to MACHINE`.
    To(String),
}

/// What is known of a place's room.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Headroom {
    /// Read just now and within its budget.
    Room,
    /// Read just now and over its budget: the phrases why.
    Full(Vec<String>),
    /// Could not be read.
    Unknown,
    /// Read too long ago to count.
    Stale,
}

/// A place work could go, and its room.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Room {
    pub place: String,
    pub headroom: Headroom,
}

/// Where the work runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "at", content = "place", rename_all = "snake_case")]
pub enum Placement {
    Here,
    There(String),
}

/// Why, as data.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "code", rename_all = "snake_case")]
pub enum Reason {
    /// `--here`.
    AskedHere,
    /// `--to MACHINE`.
    AskedThere,
    /// Auto is off, and the work did not come through the spill verb.
    AutoOff,
    /// Auto is on but the command matches no rule.
    NoRule,
    /// No budget level was read for this host: never over.
    BudgetUnknown,
    /// This host is within budget.
    WithinBudget { level: Level },
    /// This host is over budget, and `place` has room.
    OverBudget { level: Level, over: Vec<String> },
    /// This host is over budget and no place has room: each place and its room.
    NoRoom { level: Level, over: Vec<String>, places: Vec<Room> },
}

/// This host's budget as the decision reads it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct HereBudget {
    pub level: Level,
    /// The verdict's phrases (`load1 9.0 >= 8 (8 cores)`).
    pub over: Vec<String>,
}

/// The decision's inputs (module docs).
#[derive(Debug, Clone)]
pub struct Inputs<'a> {
    pub work: Work<'a>,
    pub asked: Asked,
    /// `None`: no level was read.
    pub here: Option<HereBudget>,
    pub setting: &'a Setting,
    pub force: Override,
}

/// The decision: a place and why.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Decision {
    pub placement: Placement,
    pub reason: Reason,
}

impl Decision {
    fn here(reason: Reason) -> Self {
        Self { placement: Placement::Here, reason }
    }

    /// Whether the work leaves this host.
    pub fn spills(&self) -> bool {
        matches!(self.placement, Placement::There(_))
    }
}

/// Where `inputs`' work runs (module docs). `places` is called only when this
/// host is over budget, in the order the places are preferred.
pub fn decide(inputs: &Inputs<'_>, places: impl FnOnce() -> Vec<Room>) -> Decision {
    match &inputs.force {
        Override::Here => return Decision::here(Reason::AskedHere),
        Override::To(place) => {
            return Decision {
                placement: Placement::There(place.clone()),
                reason: Reason::AskedThere,
            };
        }
        Override::None => {}
    }
    if inputs.asked == Asked::Auto {
        if !inputs.setting.auto {
            return Decision::here(Reason::AutoOff);
        }
        if let Work::Command(argv) = inputs.work
            && !inputs.setting.rules.iter().any(|rule| matches_rule(rule, argv))
        {
            return Decision::here(Reason::NoRule);
        }
    }
    let Some(here) = &inputs.here else {
        return Decision::here(Reason::BudgetUnknown);
    };
    if here.level < Level::Warning {
        return Decision::here(Reason::WithinBudget { level: here.level });
    }
    let places = places();
    match places.iter().find(|room| room.headroom == Headroom::Room) {
        Some(room) => Decision {
            placement: Placement::There(room.place.clone()),
            reason: Reason::OverBudget { level: here.level, over: here.over.clone() },
        },
        None => {
            Decision::here(Reason::NoRoom { level: here.level, over: here.over.clone(), places })
        }
    }
}

/// Whether `argv` starts with `rule`'s words; the first word by file name.
pub fn matches_rule(rule: &str, argv: &[String]) -> bool {
    let words: Vec<&str> = rule.split_whitespace().collect();
    if words.is_empty() || argv.len() < words.len() {
        return false;
    }
    words.iter().zip(argv).enumerate().all(|(i, (word, arg))| {
        let arg = if i == 0 { arg.rsplit('/').next().unwrap_or(arg) } else { arg.as_str() };
        *word == arg
    })
}

impl std::fmt::Display for Reason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::AskedHere => write!(f, "asked to run here"),
            Self::AskedThere => write!(f, "asked to run there"),
            Self::AutoOff => write!(f, "Auto is off"),
            Self::NoRule => write!(f, "the command matches no Auto rule"),
            Self::BudgetUnknown => write!(f, "this machine's budget could not be read"),
            Self::WithinBudget { level } => write!(f, "this machine is within budget ({level:?})"),
            Self::OverBudget { level, over } | Self::NoRoom { level, over, .. } => {
                write!(f, "this machine is over budget ({level:?}")?;
                if !over.is_empty() {
                    write!(f, ": {}", over.join("; "))?;
                }
                write!(f, ")")?;
                if let Self::NoRoom { places, .. } = self {
                    if places.is_empty() {
                        write!(f, " and no other machine is available")?;
                    } else {
                        let each: Vec<String> = places
                            .iter()
                            .map(|r| format!("{} {}", r.place, headroom_word(&r.headroom)))
                            .collect();
                        write!(f, " and no other machine has room ({})", each.join(", "))?;
                    }
                }
                Ok(())
            }
        }
    }
}

/// A shell script that prints a Linux machine's readings for [`linux_headroom`]:
/// `nproc`, then `/proc/loadavg`, `/proc/meminfo` and `/proc/pressure/memory`,
/// each after a marker line. It reads only, and costs one process round trip.
pub const LINUX_PROBE_SCRIPT: &str = "echo @nproc; nproc; echo @loadavg; cat /proc/loadavg; \
echo @meminfo; cat /proc/meminfo; echo @psi; cat /proc/pressure/memory 2>/dev/null; true";

/// A place's room from [`LINUX_PROBE_SCRIPT`]'s output, judged by the same
/// formula as this host ([`crate::evaluate`], the built-in budget). No load or
/// no CPU count read is [`Headroom::Unknown`], never room.
pub fn linux_headroom(output: &str) -> Headroom {
    let mut sections: std::collections::BTreeMap<&str, String> = Default::default();
    let mut current = None;
    for line in output.lines() {
        if let Some(name) = line.strip_prefix('@') {
            current = Some(name.trim());
            continue;
        }
        if let Some(name) = current {
            let text = sections.entry(name).or_default();
            text.push_str(line);
            text.push('\n');
        }
    }
    let section = |name: &str| sections.get(name).map(String::as_str).unwrap_or_default();
    let Some(cpus) = section("nproc").trim().parse::<u32>().ok().filter(|n| *n > 0) else {
        return Headroom::Unknown;
    };
    let Some(load1) = crate::parse_loadavg(section("loadavg")) else {
        return Headroom::Unknown;
    };
    let sample = crate::Sample {
        load1: Some(load1),
        logical_cpus: cpus,
        psi_some_avg10: crate::parse_psi_some_avg10(section("psi")),
        available_ram_fraction: crate::parse_meminfo_available(section("meminfo")),
        ..crate::Sample::default()
    };
    let verdict = crate::evaluate("place", &sample, None, &crate::Budget::default());
    if verdict.ok { Headroom::Room } else { Headroom::Full(verdict.over) }
}

fn headroom_word(headroom: &Headroom) -> String {
    match headroom {
        Headroom::Room => "has room".into(),
        Headroom::Full(over) => format!("is full: {}", over.join("; ")),
        Headroom::Unknown => "room unknown".into(),
        Headroom::Stale => "room stale".into(),
    }
}

#[cfg(test)]
#[path = "place_tests.rs"]
mod tests;
