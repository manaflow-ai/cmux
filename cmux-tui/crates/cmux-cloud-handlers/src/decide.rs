//! The Cloud handlers' decisions: what a run means and what it does next. The
//! app reads the facts off its models (the target, the windows, the machine
//! list, the creation), asks here, and does the platform work.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::args::PortNames;
use crate::fields::{self, Machine};
use crate::{Fields, Said};

/// Which machine an invocation acts on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Pick {
    /// The machine its `--target machine:<id>` names.
    Named,
    /// The machine of the active window's workspace.
    Active,
    /// The only Cloud machine.
    Only,
}

/// The facts of a machine lookup.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Lookup {
    /// The `machine:` target's id, when the run has one.
    pub named: Option<String>,
    /// That id names a machine of the list (its Cloud id, or a connected one's `machine_…` id).
    pub named_found: bool,
    /// A person's own gesture in this app (the run's outermost origin is `user`).
    pub by_user: bool,
    /// The active window shows a Cloud machine's workspace.
    pub active_found: bool,
    pub cloud_count: usize,
}

/// Only a person's own gesture may mean "the machine I'm looking at" (the active window's,
/// else the only one). A CLI, MCP, script, page or remote run must name its machine: an
/// agent's `cloud kill-machine --confirm true` never kills whatever machine the window shows.
pub fn machine(lookup: &Lookup) -> Result<Pick, Said> {
    if let Some(id) = &lookup.named {
        return if lookup.named_found {
            Ok(Pick::Named)
        } else {
            Err(Said::with("unknownMachine", [id.clone()]).not_found())
        };
    }
    if !lookup.by_user {
        return Err(Said::key("noMachine"));
    }
    if lookup.active_found {
        return Ok(Pick::Active);
    }
    if lookup.cloud_count == 1 { Ok(Pick::Only) } else { Err(Said::key("noMachine")) }
}

/// What New Cloud Workspace does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NewWorkspace {
    /// The person's workspace setup (the wizard) for a new machine of its own.
    Setup,
    /// A new machine whose progress shows now; a CLI or agent hears it once the server has it.
    NewMachine,
    /// The named or focused machine is on its way (or paused): it connects, the answer is pending.
    Connecting,
    /// A workspace on the machine, now.
    Workspace,
}

/// New Cloud Workspace on `has_target` (the machine it opens on, if not a new one), which is
/// `connected` or not; a person's run with a window opens the setup.
pub fn new_workspace(
    has_target: bool,
    connected: bool,
    by_user: bool,
    has_window: bool,
) -> NewWorkspace {
    match (has_target, connected) {
        (true, true) => NewWorkspace::Workspace,
        (true, false) => NewWorkspace::Connecting,
        (false, _) if by_user && has_window => NewWorkspace::Setup,
        (false, _) => NewWorkspace::NewMachine,
    }
}

/// What New Cloud Machine starts once signed in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NewMachineStart {
    /// The person's workspace setup.
    Setup,
    /// The create with the run's options (size, bootstrap, repo, machine config).
    Requested,
    /// The default create, answered once the server has the machine.
    Default,
}

pub fn new_machine_start(is_default: bool, by_user: bool, has_window: bool) -> NewMachineStart {
    match (is_default, by_user && has_window) {
        (true, true) => NewMachineStart::Setup,
        (false, _) => NewMachineStart::Requested,
        (true, false) => NewMachineStart::Default,
    }
}

/// Where the workspace setup's creation is. Mirroring removes the progress row normally;
/// explicit teardown ends the wizard even when it already opened a workspace.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Readiness {
    Waiting,
    Ready,
    Ended,
}

pub fn setup_readiness(torn_down: bool, has_workspace: bool, listed: bool) -> Readiness {
    if torn_down {
        Readiness::Ended
    } else if has_workspace {
        Readiness::Ready
    } else if listed {
        Readiness::Waiting
    } else {
        Readiness::Ended
    }
}

/// Where a creation is, as a CLI's `new-machine` waits on it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Creation {
    Pending,
    Created,
    Failed,
    /// No longer listed: declined, dismissed or its machine removed.
    Gone,
}

/// The creation's state from its facts: still `listed`, its machine (`has_session`), `failed`.
pub fn creation(listed: bool, has_session: bool, failed: bool) -> Creation {
    match (listed, has_session, failed) {
        (false, false, _) => Creation::Gone,
        (_, true, _) => Creation::Created,
        (true, false, true) => Creation::Failed,
        (true, false, false) => Creation::Pending,
    }
}

/// The error code of a `cloud new-machine` refused for a paid plan, as the Cloud contract names it.
pub const PLAN_REQUIRED_CODE: &str = "cloud.plan.required";

/// How a `cloud new-machine` from a CLI or agent settled.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settled {
    /// None: the wait ended first.
    pub state: Option<Creation>,
    pub reason: Option<String>,
    pub creation_id: String,
    /// The machine, once the server returned it.
    pub machine: Option<Machine>,
    pub workspace_id: Option<String>,
    /// The paid plan a refusal names.
    pub plan: Option<String>,
}

/// A run's failure: its reason, the error code a caller can act on, and whether it is a
/// refusal (`unavailable`) rather than a failed run.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Failure {
    pub reason: Said,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<&'static str>,
    pub refusal: bool,
}

/// The answer of a settled (or still pending) create: the machine, `pending` with the
/// creation's id, or the failure. A refusal a paid plan lifts names the plan, so a CLI or agent
/// can start that plan's checkout (`cmux billing checkout --plan`).
pub fn settled(settled: &Settled) -> Result<Fields, Failure> {
    // A machine the server returned is made, whatever phase raced it (as `creation` decides).
    if let Some(machine) = &settled.machine {
        return Ok(fields::created_machine(machine, settled.workspace_id.as_deref()));
    }
    match settled.state {
        Some(Creation::Failed) => {
            let reason = settled.reason.as_deref().unwrap_or("");
            Err(match &settled.plan {
                Some(plan) => Failure {
                    reason: Said::text(format!("new Cloud machine: {reason} (plan: {plan})")),
                    code: Some(PLAN_REQUIRED_CODE),
                    refusal: false,
                },
                None => Failure {
                    reason: Said::text(format!("new Cloud machine: {reason}")),
                    code: None,
                    refusal: false,
                },
            })
        }
        Some(Creation::Gone) => {
            Err(Failure { reason: Said::key("createDeclined"), code: None, refusal: true })
        }
        _ => Ok(
            match json!({"pending": true, "status": "creating", "creation_id": settled.creation_id})
            {
                Value::Object(map) => map,
                _ => Fields::new(),
            },
        ),
    }
}

/// How Open Desktop shows a machine's desktop.
/// A Cloud machine's state, as the diagnostics summary reads it.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Diagnosed {
    pub title: String,
    /// Why its link failed.
    pub failure: Option<String>,
    /// The app's words for its daemon's compatibility, when it is not current.
    pub compatibility: Option<String>,
}

/// The diagnostics' one line: the first thing that needs the person, else that all is well.
pub fn diagnostics_summary(
    unavailable: Option<&str>,
    signed_in: bool,
    machines: &[Diagnosed],
    account_label: &str,
) -> Said {
    if let Some(reason) = unavailable {
        return Said::text(reason);
    }
    if !signed_in {
        return Said::key("signInFirst");
    }
    for machine in machines {
        if let Some(why) = machine.failure.as_ref().or(machine.compatibility.as_ref()) {
            return Said::text(format!("{}: {why}", machine.title));
        }
    }
    Said::with("diagnosticsAllWell", [account_label])
}

/// A team the account belongs to.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct Team {
    pub id: String,
    pub name: String,
}

/// Switch Active Team's `team` (an id or a name): the team to select, or none when it is the
/// active one already.
pub fn team(
    teams: &[Team],
    active: Option<&str>,
    asked: Option<&str>,
) -> Result<Option<String>, Said> {
    if teams.is_empty() {
        return Err(Said::key("noTeams"));
    }
    let team = asked
        .and_then(|asked| teams.iter().find(|team| team.id == asked || team.name == asked))
        .ok_or_else(|| Said::with("noSuchTeam", [asked.unwrap_or("")]).invalid_target())?;
    Ok((Some(team.id.as_str()) != active).then(|| team.id.clone()))
}

/// Why Set Up GitHub will not use the App, as the GitHub App check answered (`ready` is none).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GitHubApp {
    Ready,
    NotConnected,
    NotConfigured,
    Unknown,
}

/// What Set Up GitHub's question says: the App's helper, else the machine's own sign-in with the
/// fallback's reason first. The parts are the app's strings, said in order; the bodies name the
/// machine's git identity (`—` for a missing name or email).
pub fn github_confirm(name: Option<&str>, email: Option<&str>, app: GitHubApp) -> Vec<Said> {
    let named = name.is_some() || email.is_some();
    let identity = [name.unwrap_or("—"), email.unwrap_or("—")];
    let body = |key: &'static str, bare: &'static str| {
        if named { Said::with(key, identity) } else { Said::key(bare) }
    };
    let reason = match app {
        GitHubApp::Ready => {
            return vec![body("gitHubAppConfirmBody", "gitHubAppConfirmNoIdentity")];
        }
        GitHubApp::NotConnected => "gitHubFallbackNotConnected",
        GitHubApp::NotConfigured => "gitHubFallbackNotConfigured",
        GitHubApp::Unknown => "gitHubFallbackUnknown",
    };
    vec![Said::key(reason), body("gitHubConfirmBody", "gitHubConfirmNoIdentity")]
}

/// An error's own words, without a trailing period (it sits inside a sentence).
pub fn detail(text: &str) -> String {
    text.trim().trim_end_matches('.').to_owned()
}

/// The refusal of a failed port op, with the machine and port named: the plan's forward limit
/// (`portLimit`), else what failed (`portFailed`, its detail last).
pub fn port_failure(code: Option<&str>, text: &str, names: &PortNames) -> Said {
    match code {
        Some("cmux.cloud.port_limit") => names.said("portLimit", &[]),
        _ => names.said("portFailed", &[&detail(text)]),
    }
}

#[cfg(test)]
#[path = "decide/tests.rs"]
mod tests;
