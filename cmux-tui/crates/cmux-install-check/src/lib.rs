//! cmux NEXT NIGHTLY's install check (RFD 0028, item 6).
//!
//! After an update installs, the app opens one canary chat connection: the
//! hello a chat pane sends to the acpmux daemon the new build runs. This crate
//! decides what follows from that result, and keeps the record of which
//! builds passed.
//!
//! - Passed: keep the build and record it as passing.
//! - Refused: record it as refused and pin it so it is never a rollback
//!   target. Roll app and daemon back together to the newest kept build that
//!   passed this same check and can read the stores. With no passing build
//!   kept, or none that reads the stores, stay and report.
//! - Inconclusive (the daemon never answered in time, or refused with an
//!   error it marks retryable, such as `connection.busy`): keep, record
//!   nothing, so the next launch checks again.
//!
//! A rollback relaunches the app, so its notice is held in the record and
//! shown once on the next launch ([`show`]): rolled back when the target
//! build runs, rollback failed when the refused build still runs.
//!
//! [`decide`] is pure. [`run`] is the bundled CLI's `__install-check` mode
//! the app calls: it loads the record, decides, saves, and prints the
//! decision as JSON. The app writes the one line it shows the person from
//! [`Notice`], in their language.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

/// The most builds the record keeps, newest last.
pub const HISTORY_LIMIT: usize = 64;

/// What the canary chat connection found.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "result", rename_all = "camelCase")]
pub enum Canary {
    /// The daemon answered the hello.
    Passed,
    /// The hello was refused; `reason` is the refusal as the chat would see it.
    /// A `retryable` refusal (the JSON-RPC error's `data.retryable`, e.g.
    /// `connection.busy`) says nothing about the build: it is inconclusive.
    Refused {
        reason: String,
        #[serde(default)]
        retryable: bool,
    },
    /// No answer either way (timeout, daemon not ready).
    Inconclusive,
}

/// A build's recorded check result.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Outcome {
    Passed,
    Refused,
}

/// One build's line in the record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub build: String,
    pub result: Outcome,
}

/// A build the app kept on disk that a rollback could swap in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Kept {
    pub build: String,
    /// Whether that build can read the stores on disk now (the app's
    /// existing rollback check: signature, store schemas).
    pub reads_store: bool,
}

/// Everything the decision reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Input {
    /// The running build is a NIGHTLY. Every other channel keeps, untouched.
    pub nightly: bool,
    /// The running build.
    pub build: String,
    pub canary: Canary,
    /// Recorded check results, oldest first.
    #[serde(default)]
    pub history: Vec<Entry>,
    /// Builds that were refused and must not be rolled back to.
    #[serde(default)]
    pub pinned: Vec<String>,
    /// Kept builds, newest first.
    #[serde(default)]
    pub kept: Vec<Kept>,
}

/// Why a refused build stays.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Why {
    /// No kept build is recorded as passing this check.
    NoPassingBuild,
    /// Builds that passed are kept, but none can read the stores now.
    StoreUnreadable,
}

/// What the app does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Action {
    Keep,
    RollBack { to: String },
    Report { why: Why },
}

/// The one line the person sees, as data; the app words it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Notice {
    /// The refused build.
    pub build: String,
    /// The build it rolled back to; none when it stayed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    /// Why it stayed; none when it rolled back.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub why: Option<Why>,
    /// The refusal.
    pub reason: String,
}

/// The decision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub action: Action,
    /// The result to record for the running build.
    pub record: Option<Entry>,
    /// The build to pin.
    pub pin: Option<String>,
    pub notice: Option<Notice>,
}

impl Decision {
    fn keep() -> Self {
        Decision { action: Action::Keep, record: None, pin: None, notice: None }
    }
}

/// Whether the running build still needs its check: it is a NIGHTLY and the
/// record holds no result for it.
pub fn due(nightly: bool, build: &str, history: &[Entry]) -> bool {
    nightly && !history.iter().any(|entry| entry.build == build)
}

/// The decision for `input`. Pure.
pub fn decide(input: &Input) -> Decision {
    if !due(input.nightly, &input.build, &input.history) {
        return Decision::keep();
    }
    let reason = match &input.canary {
        Canary::Inconclusive | Canary::Refused { retryable: true, .. } => return Decision::keep(),
        Canary::Passed => {
            return Decision {
                record: Some(Entry { build: input.build.clone(), result: Outcome::Passed }),
                ..Decision::keep()
            };
        }
        Canary::Refused { reason, retryable: false } => reason.clone(),
    };
    let passed = |build: &str| {
        input.history.iter().any(|entry| entry.build == build && entry.result == Outcome::Passed)
    };
    let mut candidates = input.kept.iter().filter(|kept| {
        kept.build != input.build && !input.pinned.contains(&kept.build) && passed(&kept.build)
    });
    let (action, target, why) = match candidates.clone().find(|kept| kept.reads_store) {
        Some(kept) => (Action::RollBack { to: kept.build.clone() }, Some(kept.build.clone()), None),
        None if candidates.next().is_some() => {
            (Action::Report { why: Why::StoreUnreadable }, None, Some(Why::StoreUnreadable))
        }
        None => (Action::Report { why: Why::NoPassingBuild }, None, Some(Why::NoPassingBuild)),
    };
    Decision {
        action,
        record: Some(Entry { build: input.build.clone(), result: Outcome::Refused }),
        pin: Some(input.build.clone()),
        notice: Some(Notice { build: input.build.clone(), target, why, reason }),
    }
}

/// A rollback's notice, held in the record until the next launch shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Held {
    pub notice: Notice,
    /// What the person reads about a rollback that did not run; none while
    /// it is under way.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
}

/// Which notice a launch shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Shown {
    /// The target build runs: the rollback happened.
    RolledBack,
    /// The refused build still runs: the rollback did not.
    RollbackFailed,
}

/// The notice a launch shows, once.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Show {
    pub kind: Shown,
    pub notice: Notice,
    /// Why the rollback did not run (`RollbackFailed`); none when the app
    /// ended before it said (a crash or a quit mid-swap).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failure: Option<String>,
}

/// What a launch running `running` shows for the `held` notice. Pure.
/// Another build running (the person moved on) shows nothing: the notice is
/// stale.
pub fn show(held: Option<&Held>, running: &str) -> Option<Show> {
    let held = held?;
    let kind = if held.failure.is_none() && held.notice.target.as_deref() == Some(running) {
        Shown::RolledBack
    } else if held.notice.build == running {
        Shown::RollbackFailed
    } else {
        return None;
    };
    let failure = if kind == Shown::RollbackFailed { held.failure.clone() } else { None };
    Some(Show { kind, notice: held.notice.clone(), failure })
}

/// The record on disk.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Record {
    #[serde(default)]
    pub history: Vec<Entry>,
    #[serde(default)]
    pub pinned: Vec<String>,
    /// A rollback's notice not shown yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub held: Option<Held>,
}

impl Record {
    /// The record at `path`; empty when the file does not exist yet.
    pub fn load(path: &Path) -> Result<Record, String> {
        match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|error| format!("{}: {error}", path.display())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Record::default()),
            Err(error) => Err(format!("{}: {error}", path.display())),
        }
    }

    /// Adds the decision's record and pin, and holds a rollback's notice for
    /// the next launch.
    pub fn apply(&mut self, decision: &Decision) {
        if let (Action::RollBack { .. }, Some(notice)) = (&decision.action, &decision.notice) {
            self.held = Some(Held { notice: notice.clone(), failure: None });
        }
        if let Some(entry) = &decision.record {
            self.history.retain(|old| old.build != entry.build);
            self.history.push(entry.clone());
            let over = self.history.len().saturating_sub(HISTORY_LIMIT);
            self.history.drain(..over);
        }
        if let Some(pin) = &decision.pin
            && !self.pinned.contains(pin)
        {
            self.pinned.push(pin.clone());
            let over = self.pinned.len().saturating_sub(HISTORY_LIMIT);
            self.pinned.drain(..over);
        }
    }

    /// Writes the record to `path` through a temporary file and a rename.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("{}: {error}", parent.display()))?;
        }
        let json = serde_json::to_vec_pretty(self).map_err(|error| error.to_string())?;
        let temporary = path.with_extension("json.tmp");
        std::fs::write(&temporary, json)
            .map_err(|error| format!("{}: {error}", temporary.display()))?;
        std::fs::rename(&temporary, path).map_err(|error| format!("{}: {error}", path.display()))
    }
}

/// What the app passes the `decide` step on stdin: the decision's input
/// without the record, which the CLI reads from `--record`.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    nightly: bool,
    build: String,
    canary: Canary,
    #[serde(default)]
    kept: Vec<Kept>,
}

fn record_path(args: &[String]) -> Result<PathBuf, String> {
    flag(args, "--record").map(PathBuf::from).ok_or_else(|| "missing --record FILE".to_string())
}

fn flag<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.windows(2).find_map(|pair| match pair {
        [key, value] if key == name => Some(value.as_str()),
        _ => None,
    })
}

/// The `__install-check` mode. `due --record FILE --build B [--nightly]`
/// prints `{"due":BOOL}`; `decide --record FILE` reads a request on `stdin`,
/// saves the record and pin, and prints the [`Decision`]; `failed --record
/// FILE --failure TEXT` marks the held rollback as not run; `show --record
/// FILE --build B` prints the [`Show`] for build `B` (or `null`) and drops the
/// held notice, so it shows once.
pub fn run(args: &[String], stdin: &str) -> Result<String, String> {
    let record = record_path(args)?;
    match args.first().map(String::as_str) {
        Some("failed") => {
            let failure = flag(args, "--failure").ok_or("missing --failure TEXT")?;
            let mut saved = Record::load(&record)?;
            if let Some(held) = &mut saved.held {
                held.failure = Some(failure.to_string());
                saved.save(&record)?;
            }
            Ok("{}".to_string())
        }
        Some("show") => {
            let build = flag(args, "--build").ok_or("missing --build BUILD")?;
            let mut saved = Record::load(&record)?;
            let shown = show(saved.held.as_ref(), build);
            if saved.held.take().is_some() {
                saved.save(&record)?;
            }
            serde_json::to_string(&shown).map_err(|error| error.to_string())
        }
        Some("due") => {
            let build = flag(args, "--build").ok_or("missing --build BUILD")?;
            let nightly = args.iter().any(|arg| arg == "--nightly");
            let history = Record::load(&record)?.history;
            Ok(serde_json::json!({ "due": due(nightly, build, &history) }).to_string())
        }
        Some("decide") => {
            let request: Request =
                serde_json::from_str(stdin).map_err(|error| format!("request: {error}"))?;
            let mut saved = Record::load(&record)?;
            let decision = decide(&Input {
                nightly: request.nightly,
                build: request.build,
                canary: request.canary,
                history: saved.history.clone(),
                pinned: saved.pinned.clone(),
                kept: request.kept,
            });
            if decision.record.is_some() || decision.pin.is_some() || decision.notice.is_some() {
                saved.apply(&decision);
                saved.save(&record)?;
            }
            serde_json::to_string(&decision).map_err(|error| error.to_string())
        }
        _ => Err("usage: __install-check due|decide|failed|show --record FILE ...".to_string()),
    }
}

#[cfg(test)]
mod tests;
