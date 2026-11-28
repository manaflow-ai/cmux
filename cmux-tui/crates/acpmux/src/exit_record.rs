//! Exit records: a session's end reaches the session that started it, the way `wait()` hands a
//! child's exit status to its parent (RFD 0177 §5, build 5, in cmuxterm-hq
//! `docs/rfd/0177-kernel-proc-lifecycle.md`).
//!
//! Leo, 2026-11-24: "also try to fix up whateve occured that closed the lanes when they weren't
//! finished? we need to be more persistent somehow when agents die but they have important work".
//! Every close already writes its close record (`close_why.rs`): who closed it, why, and whether
//! its work was done. Before this, that record stayed in the closed chat: a lane closed with an
//! open PR or a goal reached no parent (lane death watch never reads a closed row, and the lane's
//! report link is retired with the close). Now the close also makes an **exit record** and the
//! daemon puts it in the parent's chat once (`hub/exit_notify.rs`). The record holds:
//!
//! - its exit class: `done`, `dropped`, `crashed` (the harness ended it) or `killed` (anything
//!   else closed it with its work unfinished);
//! - the close's reason and closer;
//! - what it owned: the pull requests its reports named, its goal, the role addresses it claimed,
//!   its folder;
//! - its checkpoint: the harness transcript id and the command that reads its log.
//!
//! A parent that is closed passes the record up to its own parent, the way an orphan reparents
//! (at most [`MAX_HOPS`]). This module is the pure part: no hub, no clock.

use crate::close_why::CloseRecord;
use crate::store::SessionMeta;
use serde::Serialize;

/// The provenance kind of the notice (`hub/queue_origin.rs` lists it as acpmux's own).
pub const KIND: &str = "exit_record";

/// Parents walked up past closed ones at most.
pub const MAX_HOPS: usize = 8;

/// The tags that name who started a session, first found wins (`lane_death_watch.rs` reads the
/// same ones from a peer's row).
pub const PARENT_TAGS: [&str; 3] =
    ["mux.parent", crate::meta_fields::SPAWNED_BY_TAG, "lane.reportsTo"];

/// Whether exit records are delivered (`ACPMUX_EXIT_RECORDS=0` turns it off).
pub fn enabled() -> bool {
    std::env::var("ACPMUX_EXIT_RECORDS").map_or(true, |v| v.trim() != "0")
}

/// How a session ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ExitClass {
    /// Its closer said its work was done.
    Done,
    /// Closed with nothing anyone waits on.
    Dropped,
    /// Its harness ended and took the chat with it, work unfinished.
    Crashed,
    /// Something else closed it with its work unfinished.
    Killed,
}

impl ExitClass {
    pub fn of(close: &CloseRecord) -> Self {
        match close.outcome.as_str() {
            "done" => Self::Done,
            "dropped" => Self::Dropped,
            _ if close.actor.kind == "harness_exit" => Self::Crashed,
            _ => Self::Killed,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Done => "done",
            Self::Dropped => "dropped",
            Self::Crashed => "crashed",
            Self::Killed => "killed",
        }
    }
}

/// What a session owned when it ended.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Owned {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub prs: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub goal: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub roles: Vec<String>,
    pub folder: String,
}

impl Owned {
    /// Whether it owned anything someone has to pick up (its folder alone is not).
    pub fn any(&self) -> bool {
        !self.prs.is_empty() || self.goal.is_some() || !self.roles.is_empty()
    }
}

/// One session's exit record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ExitRecord {
    pub session: String,
    pub name: String,
    pub class: ExitClass,
    pub close: CloseRecord,
    pub owned: Owned,
    /// The harness transcript id (`claude --resume` / Codex thread), when it had one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcript: Option<String>,
    pub harness: String,
}

/// The goal a session holds unfinished: its harness goal not done, else its `goal` tag.
fn open_goal(meta: &SessionMeta) -> Option<String> {
    if let Some(g) = &meta.goal
        && g.status != crate::goal::GoalStatus::Done
    {
        return Some(g.objective.clone());
    }
    meta.tags.get("goal").map(|t| t.value.trim().to_owned()).filter(|s| !s.is_empty())
}

impl ExitRecord {
    /// The record of `meta`'s close; `prs` are the pull requests its lane reports named.
    pub fn new(meta: &SessionMeta, close: CloseRecord, prs: Vec<String>) -> Self {
        Self {
            session: meta.id.clone(),
            name: meta.name.clone(),
            class: ExitClass::of(&close),
            owned: Owned {
                prs,
                goal: open_goal(meta),
                roles: meta.roles.iter().map(|r| r.address.clone()).collect(),
                folder: meta.cwd.display().to_string(),
            },
            close,
            transcript: meta.agent_session_id.clone(),
            harness: meta.harness.clone(),
        }
    }

    /// The prompt id: the same for every try of this close, so a resend never doubles it.
    pub fn prompt_id(&self) -> String {
        format!("exit-{}-{}", self.session, self.close.closed_at)
    }

    /// The text the parent reads. `via` names the closed sessions it passed through on its way
    /// up, nearest first.
    pub fn text(&self, via: &[String]) -> String {
        let mut out = format!(
            "[exit] `{}`, which {}, ended {}: {} (closed by {}).",
            self.name,
            if via.is_empty() {
                "you started".to_owned()
            } else {
                format!("`{}` started (closed, so it comes to you)", via.join("` < `"))
            },
            self.class.as_str(),
            self.close.reason,
            self.close.actor.kind,
        );
        let o = &self.owned;
        if o.any() {
            let mut owned = vec![];
            if !o.prs.is_empty() {
                owned.push(format!("PRs {}", o.prs.join(", ")));
            }
            if let Some(g) = &o.goal {
                owned.push(format!("goal \"{}\"", cut(g, 160)));
            }
            if !o.roles.is_empty() {
                owned.push(format!("roles {}", o.roles.join(", ")));
            }
            out.push_str(&format!(" It owned: {}; that work is yours now.", owned.join("; ")));
        }
        out.push_str(&format!(" Folder: `{}`.", o.folder));
        if let Some(t) = &self.transcript {
            out.push_str(&format!(" Checkpoint: {} transcript `{t}`;", self.harness));
        } else {
            out.push_str(" Checkpoint:");
        }
        out.push_str(&format!(" read it with `acpmux session tail {}`.", self.name));
        out
    }
}

/// `s` cut to `n` characters, with `…` when cut.
fn cut(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_owned();
    }
    let mut out: String = s.chars().take(n).collect();
    out.push('…');
    out
}

/// The parent `meta`'s tags name, first found wins.
pub fn parent_tag(meta: &SessionMeta) -> Option<String> {
    PARENT_TAGS
        .iter()
        .find_map(|t| meta.tags.get(*t).map(|v| v.value.trim()).filter(|s| !s.is_empty()))
        .map(str::to_owned)
}

#[cfg(test)]
#[path = "exit_record_tests.rs"]
mod tests;
