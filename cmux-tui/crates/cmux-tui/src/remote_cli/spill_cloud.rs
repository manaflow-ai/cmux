//! `cmux spill`'s Cloud place: the signed-in person's cmux Cloud machine.
//!
//! With no ROUTE (or ROUTE `cloud`, `cloud:MACHINE`), the place is a Cloud
//! machine from the app's `cloud.machines` rows: the one named, else the first
//! whose link is connected, else the first running. The CLI dials its own
//! carrier session to it with the app's `auth.token` credential
//! ([`crate::carrier::workspace`]) and runs `remote exec`'s protocol on it.
//! When there is none, the miss names the one step that would make one.

use std::time::Duration;

use serde_json::Value;

use crate::carrier::workspace::{WorkspaceSession, dial_workspace};

/// How long the carrier dial (ticket, relay, handshake) may take.
const DIAL_DEADLINE: Duration = Duration::from_secs(60);

/// Whether the connect words name the Cloud place: none at all, or ROUTE
/// `cloud` / `cloud:MACHINE`.
pub(super) fn is_cloud(connect: &[String], route: Option<&str>) -> bool {
    connect.is_empty() || route.is_some_and(|route| route == "cloud" || route.starts_with("cloud:"))
}

/// The machine `cloud:NAME` names, `None` for plain `cloud` or no ROUTE.
fn selector(route: Option<&str>) -> Option<&str> {
    route.and_then(|route| route.strip_prefix("cloud:")).filter(|name| !name.is_empty())
}

/// The Cloud machine spilled to.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct CloudMachine {
    pub(super) id: String,
    pub(super) title: String,
    pub(super) team: Option<String>,
}

/// Why there is no Cloud machine to spill to.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Miss {
    /// No cmux app answers on this host.
    NoApp,
    /// The app is not signed in.
    NotSignedIn,
    /// Signed in, no Cloud machine.
    NoMachine,
    /// `cloud:NAME` names none.
    NotFound(String),
    /// The machine is not running.
    Asleep(String),
    /// The dial or the token mint was refused.
    Failed(String),
}

impl Miss {
    /// The one step that would enable spilling.
    pub(super) fn step(&self) -> String {
        match self {
            Self::NoApp => "open the cmux app and sign in".into(),
            Self::NotSignedIn => "sign in to cmux in the app".into(),
            Self::NoMachine => "make a Cloud machine: cmux vm new".into(),
            Self::NotFound(name) => {
                format!("no Cloud machine is named {name:?}; see cmux vm ls")
            }
            Self::Asleep(id) => format!("start your Cloud machine: cmux vm resume {id}"),
            Self::Failed(why) => format!("the Cloud machine did not connect ({why})"),
        }
    }
}

/// The machine to spill to among the app's rows (`None`: no app answered).
pub(super) fn pick(rows: Option<&[Value]>, route: Option<&str>) -> Result<CloudMachine, Miss> {
    let rows = rows.ok_or(Miss::NoApp)?;
    let text = |row: &Value, key: &str| row.get(key).and_then(Value::as_str).map(str::to_owned);
    let live: Vec<&Value> =
        rows.iter().filter(|row| text(row, "status").as_deref() != Some("destroyed")).collect();
    let chosen = if let Some(name) = selector(route) {
        let owned: Vec<Value> = live.iter().map(|row| (*row).clone()).collect();
        let found = crate::cli::find_cloud_machine(&owned, name).map_err(Miss::Failed)?;
        found.cloned().ok_or_else(|| Miss::NotFound(name.to_owned()))?
    } else {
        let connected = live.iter().find(|row| text(row, "daemon").as_deref() == Some("connected"));
        let running = live.iter().find(|row| text(row, "status").as_deref() == Some("running"));
        match connected.or(running).or(live.first()) {
            Some(row) => (*row).clone(),
            None => return Err(Miss::NoMachine),
        }
    };
    let id = text(&chosen, "id").ok_or(Miss::NoMachine)?;
    let connected = text(&chosen, "daemon").as_deref() == Some("connected");
    if !connected && text(&chosen, "status").as_deref() != Some("running") {
        return Err(Miss::Asleep(id));
    }
    Ok(CloudMachine {
        title: text(&chosen, "title").unwrap_or_else(|| id.clone()),
        team: text(&chosen, "team").filter(|team| !team.is_empty()),
        id,
    })
}

/// A miss from the app's `auth.token` refusal code.
pub(super) fn token_miss(code: &str) -> Miss {
    match code {
        "not_signed_in" | "no_team" => Miss::NotSignedIn,
        "app.unreachable" | "app.not_found" | "socket.no_app" => Miss::NoApp,
        other => Miss::Failed(other.to_owned()),
    }
}

/// Resolves and dials the Cloud place. `Ok`: its name and an open session.
pub(super) fn open(
    runtime: &tokio::runtime::Runtime,
    route: Option<&str>,
) -> Result<(String, WorkspaceSession), Miss> {
    let rows = crate::cli::app_cloud_machines();
    let machine = pick(rows.as_deref(), route)?;
    let token =
        crate::cli::app_token_in(machine.team.as_deref()).map_err(|code| token_miss(&code))?;
    let team = machine.team.clone().or(Some(token.team.clone()));
    let session = runtime
        .block_on(dial_workspace(&machine.id, &token.api_origin, token.token, team, DIAL_DEADLINE))
        .map_err(Miss::Failed)?;
    Ok((format!("Cloud machine {}", machine.title), session))
}
