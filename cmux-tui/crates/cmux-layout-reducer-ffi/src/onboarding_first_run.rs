//! `cmux-window-rules::onboarding_first_run` over the JSON channel (ops
//! `onboarding_first_run_*`): the project scan's grouping, folder rules,
//! ranking and completion, the Set Up card's launch route and Chief form,
//! the Opacity slider's step and the classic migration's next step. The app
//! reads the session files, probes the folders, reads its defaults and the
//! daemon's replies, sends them here and acts on the answer.

use cmux_window_rules::onboarding_first_run::{
    self as first_run, Answer, CardState, ChiefFacts, FolderVerdict, LaunchFacts, Mode, ProbeFacts,
    Project, ReplyFacts, Repository, Session,
};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's. Narrower than the
/// onboarding footer's `onboarding_` ops, so it is asked first.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"onboarding_first_run_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn write<T: Serialize>(answer: &T) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(answer).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Group {
    #[serde(default)]
    sessions: Vec<Session>,
    #[serde(default)]
    repositories: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Folders {
    home: String,
    #[serde(default)]
    agent_homes: Vec<String>,
    #[serde(default)]
    paths: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Rank {
    now: f64,
    #[serde(default)]
    projects: Vec<Project>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Recent {
    now: f64,
    limit: usize,
    #[serde(default)]
    projects: Vec<Project>,
    #[serde(default)]
    hints: Vec<String>,
    #[serde(default)]
    repositories: Vec<Repository>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Complete {
    #[serde(default)]
    paths: Vec<String>,
    #[serde(default)]
    raw: String,
    #[serde(default)]
    expanded: String,
    limit: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CardEnd {
    #[serde(default)]
    state: Option<CardState>,
    #[serde(default)]
    completion: bool,
}

#[derive(Deserialize)]
struct Opacity {
    value: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClassicLaunch {
    #[serde(default)]
    seam: Option<bool>,
    #[serde(default)]
    environment: Option<String>,
    #[serde(default, rename = "bundleID")]
    bundle_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClassicAnswer {
    mode: Mode,
    #[serde(default)]
    first_contact: bool,
    answer: Answer,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    match operation {
        // The sessions grouped by folder, with the sessionless repositories added undated.
        b"onboarding_first_run_projects" => {
            let group: Group = read(request)?;
            write(
                &json!({ "projects": first_run::group_sessions(&group.sessions, &group.repositories) }),
            )
        }
        // Which folders the app probes (protected, then existing); the rest are dropped.
        b"onboarding_first_run_folders" => {
            let folders: Folders = read(request)?;
            let probe: Vec<bool> = folders
                .paths
                .iter()
                .map(|path| {
                    first_run::folder_verdict(path, &folders.home, &folders.agent_homes)
                        == FolderVerdict::Probe
                })
                .collect();
            write(&json!({ "probe": probe }))
        }
        // The scan's projects, best first.
        b"onboarding_first_run_rank" => {
            let rank: Rank = read(request)?;
            write(&json!({ "projects": first_run::rank(rank.projects, rank.now) }))
        }
        // The recent list: the scan's projects, the hints and the repositories, capped.
        b"onboarding_first_run_recent" => {
            let recent: Recent = read(request)?;
            write(&json!({
                "projects": first_run::recent(recent.projects, &recent.hints, &recent.repositories, recent.now, recent.limit)
            }))
        }
        // The recent paths a typed query completes to.
        b"onboarding_first_run_complete" => {
            let complete: Complete = read(request)?;
            write(&json!({
                "paths": first_run::complete(&complete.paths, &complete.raw, &complete.expanded, complete.limit)
            }))
        }
        // Whether the Set Up card shows, starts now, and the launch's route.
        b"onboarding_first_run_card" => {
            let facts: LaunchFacts = read(request)?;
            write(&json!({
                "shows": first_run::shows_at_start(&facts),
                "begins": first_run::begins(&facts),
                "route": first_run::route(&facts),
            }))
        }
        // Whether Hide (or a completion) ends the card.
        b"onboarding_first_run_card_end" => {
            let end: CardEnd = read(request)?;
            write(&json!({ "ends": first_run::ends(end.state, end.completion) }))
        }
        // Whether Chief's chat shows the card, and which form.
        b"onboarding_first_run_chief" => {
            let facts: ChiefFacts = read(request)?;
            write(&json!({
                "needsChiefAgent": first_run::needs_chief_agent(&facts),
                "cardForm": first_run::card_form(&facts),
            }))
        }
        // The Opacity slider's step (null: refused) and the stored clamp.
        b"onboarding_first_run_opacity" => {
            let opacity: Opacity = read(request)?;
            write(&json!({
                "stepped": first_run::stepped_opacity(opacity.value),
                "clamped": first_run::clamped_opacity(opacity.value),
            }))
        }
        // Whether the launch runs the classic migration by itself.
        b"onboarding_first_run_classic_launch" => {
            let launch: ClassicLaunch = read(request)?;
            write(&json!({
                "runs": first_run::classic_runs_at_launch(
                    launch.seam,
                    launch.environment.as_deref(),
                    launch.bundle_id.as_deref()
                )
            }))
        }
        // What follows the daemon's probe.
        b"onboarding_first_run_classic_probe" => {
            let facts: ProbeFacts = read(request)?;
            write(&first_run::classic_probe(&facts))
        }
        // What follows the person's answer.
        b"onboarding_first_run_classic_answer" => {
            let answer: ClassicAnswer = read(request)?;
            write(&first_run::classic_answer(answer.mode, answer.first_contact, answer.answer))
        }
        // What follows the plan reply.
        b"onboarding_first_run_classic_reply" => {
            let facts: ReplyFacts = read(request)?;
            write(&first_run::classic_reply(&facts))
        }
        _ => Err(ERR_INVALID),
    }
}
