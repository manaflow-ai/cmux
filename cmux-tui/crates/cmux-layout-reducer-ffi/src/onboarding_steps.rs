//! `cmux-window-rules`' first-run step rules and external open router over
//! the JSON channel (ops `onboarding_steps_*`): the Computer Use step (one
//! event in, the new state, its effects and view out), the Agents step's
//! listing and marks, and what a URL or file macOS hands cmux routes to.
//! The app reads the helper's grants, acpmux's agents and Foundation's URL
//! parts, sends them here and acts on the answer.

use cmux_window_rules::external_open::{self, Request, SshTarget};
use cmux_window_rules::onboarding_steps::{self, AgentsFacts, ComputerUse, Event};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's. Narrower than the
/// onboarding footer's `onboarding_` ops, so it is asked first.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"onboarding_steps_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn write<T: Serialize>(answer: &T) -> Result<Vec<u8>, i32> {
    serde_json::to_vec(answer).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Step {
    #[serde(default)]
    state: ComputerUse,
    event: Event,
}

#[derive(Deserialize)]
struct Callback {
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    path: String,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    match operation {
        // One Computer Use event: the new state, the effects in order and the view.
        b"onboarding_steps_computer_use" => {
            let step: Step = read(request)?;
            write(&onboarding_steps::computer_use(&step.state, step.event))
        }
        // The Agents step's listing, marks and the waiting install's end.
        b"onboarding_steps_agents" => {
            let facts: AgentsFacts = read(request)?;
            write(&onboarding_steps::agents(&facts))
        }
        // The Agents step's fixed table: install pages and the refusal texts.
        b"onboarding_steps_agents_table" => {
            let pages: serde_json::Map<String, serde_json::Value> = onboarding_steps::INSTALL_PAGES
                .iter()
                .map(|(agent, page)| ((*agent).to_owned(), json!(page)))
                .collect();
            write(&json!({
                "installPages": pages,
                "installedNotFound": onboarding_steps::INSTALLED_NOT_FOUND,
                "noAgentsService": onboarding_steps::NO_AGENTS_SERVICE,
            }))
        }
        // Where a URL or file macOS (or a feed link, or Handoff) hands cmux goes.
        b"onboarding_steps_external_open" => {
            let request: Request = read(request)?;
            write(&external_open::route(&request))
        }
        // Whether a link in this build's scheme is the sign-in callback.
        b"onboarding_steps_sign_in_callback" => {
            let callback: Callback = read(request)?;
            write(&json!({
                "callback": external_open::is_sign_in_callback(callback.host.as_deref(), &callback.path)
            }))
        }
        // An SSH target's confirmation text, trust key and command.
        b"onboarding_steps_ssh_target" => {
            let target: SshTarget = read(request)?;
            write(&target.strings())
        }
        // A host as SSH trust is keyed (the settings' trusted hosts).
        b"onboarding_steps_trust_key" => {
            let host: String = read(request)?;
            write(&external_open::trust_key(&host))
        }
        _ => Err(ERR_INVALID),
    }
}
