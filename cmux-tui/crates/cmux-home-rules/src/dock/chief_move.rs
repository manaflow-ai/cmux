//! "Move Chief To…": `ChiefMoveTargets` (the list) and `ChiefMovePlan` (the steps of one move)
//! (CmuxNextHomeEngine/ChiefTeleport/ChiefMoveTargets.swift, ChiefMovePlan.swift).

use serde::{Deserialize, Serialize};

/// The machine id of the cmux Cloud entry.
pub const CLOUD_ID: &str = "cloud";
/// The machine id of the This Mac entry.
pub const LOCAL_ID: &str = "local";

/// Where a target is, which decides its `--to` value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Kind {
    /// A Chief home on this Mac (`local:<dir>`).
    Local { home: String },
    /// An SSH host (`ssh:<destination>`).
    Ssh { destination: String },
    /// A paired server, moved over SSH like an SSH host; none when no SSH route exists.
    Server {
        #[serde(default)]
        destination: Option<String>,
    },
    /// The account's Cloud Chief (`cloud`, or `cloud:<its API>` off production).
    Cloud {
        #[serde(default)]
        staging: bool,
    },
}

/// A machine the list may show.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Host {
    #[serde(rename = "machineID")]
    pub machine_id: String,
    #[serde(default)]
    pub name: String,
    pub kind: Kind,
    #[serde(default)]
    pub is_online: bool,
    /// The person made it a remote group.
    #[serde(default)]
    pub is_remote_group: bool,
}

/// The person's Cloud session: signed in, to `api` when not production.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Cloud {
    SignedIn {
        /// `URL.absoluteString` of the Cloud API the app uses when not production.
        #[serde(default)]
        api: Option<String>,
    },
    SignedOut,
}

/// Why a listed target cannot be picked now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DisabledReason {
    Offline,
    #[serde(rename = "noSSHRoute")]
    NoSshRoute,
    SignInNeeded,
}

/// One target (`ChiefMoveTarget`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    #[serde(rename = "machineID")]
    pub machine_id: String,
    pub name: String,
    pub kind: Kind,
    pub to: Option<String>,
    pub disabled_reason: Option<DisabledReason>,
}

/// This Mac first, then every SSH or paired-server remote group, then cmux Cloud.
pub fn targets(local_home: &str, hosts: &[Host], cloud: &Cloud) -> Vec<Target> {
    let mut list = vec![Target {
        machine_id: LOCAL_ID.to_owned(),
        name: String::new(),
        kind: Kind::Local { home: local_home.to_owned() },
        to: Some(format!("local:{local_home}")),
        disabled_reason: None,
    }];
    for host in hosts.iter().filter(|host| host.is_remote_group) {
        let offline = (!host.is_online).then_some(DisabledReason::Offline);
        let (to, disabled_reason) = match &host.kind {
            Kind::Ssh { destination } | Kind::Server { destination: Some(destination) } => {
                (Some(format!("ssh:{destination}")), offline)
            }
            Kind::Server { destination: None } => (None, Some(DisabledReason::NoSshRoute)),
            Kind::Local { .. } | Kind::Cloud { .. } => continue,
        };
        list.push(Target {
            machine_id: host.machine_id.clone(),
            name: host.name.clone(),
            kind: host.kind.clone(),
            to,
            disabled_reason,
        });
    }
    let (to, staging, disabled_reason) = match cloud {
        Cloud::SignedIn { api } => {
            // Without a trailing slash, as the engine reads it (`api_base`).
            let base = api.as_deref().map(|api| api.trim_end_matches('/').to_owned());
            let staging = base.is_some();
            (base.map_or_else(|| "cloud".to_owned(), |base| format!("cloud:{base}")), staging, None)
        }
        Cloud::SignedOut => ("cloud".to_owned(), false, Some(DisabledReason::SignInNeeded)),
    };
    list.push(Target {
        machine_id: CLOUD_ID.to_owned(),
        name: String::new(),
        kind: Kind::Cloud { staging },
        to: Some(to),
        disabled_reason,
    });
    list
}

/// Where `move reach` runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", content = "args", rename_all = "camelCase")]
pub enum Reach {
    /// The bundled `cmux` CLI's arguments.
    Cli(Vec<String>),
    /// A command run as is on this Mac (`ssh … optchat-chief move reach`).
    Remote(Vec<String>),
    /// No home to probe (a Cloud Chief lives in the account).
    None,
}

/// The steps of one move.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MovePlan {
    pub dry_run: Vec<String>,
    #[serde(rename = "move")]
    pub move_: Vec<String>,
    pub reach: Reach,
}

fn strings(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|&part| part.to_owned()).collect()
}

fn token_args(token_file: Option<&str>) -> Vec<String> {
    token_file.map_or_else(Vec::new, |file| strings(&["--session-token-file", file]))
}

/// `ChiefMovePlan(to:kind:sourceHome:targetHome:tokenFile:)`.
pub fn plan(
    to: &str,
    kind: &Kind,
    source_home: &str,
    target_home: &str,
    token_file: Option<&str>,
) -> MovePlan {
    let tail = [strings(&["--chief-home", source_home]), token_args(token_file)].concat();
    let dry_run = [strings(&["chief", "move", "--to", to, "--dry-run"]), tail.clone()].concat();
    let move_ = [strings(&["chief", "move", "--to", to]), tail].concat();
    let reach = match kind {
        Kind::Local { home } => {
            Reach::Cli(strings(&["chief", "move", "reach", "--chief-home", home]))
        }
        Kind::Ssh { destination } | Kind::Server { destination: Some(destination) } => {
            Reach::Remote(strings(&[
                "ssh",
                "-o",
                "BatchMode=yes",
                destination,
                "optchat-chief",
                "move",
                "reach",
                "--home",
                target_home,
            ]))
        }
        Kind::Server { destination: None } | Kind::Cloud { .. } => Reach::None,
    };
    MovePlan { dry_run, move_, reach }
}

/// `cmux chief move rollback` on the app's Chief home.
pub fn rollback(source_home: &str, token_file: Option<&str>) -> Vec<String> {
    [strings(&["chief", "move", "rollback", "--chief-home", source_home]), token_args(token_file)]
        .concat()
}

/// The moving home's path under the user's home folder as `~/…`; a home outside it keeps its path.
pub fn target_home(home: &str, user_home: &str) -> String {
    let base =
        if user_home.ends_with('/') { user_home.to_owned() } else { format!("{user_home}/") };
    match home.strip_prefix(&base) {
        Some(rest) => format!("~/{rest}"),
        None => home.to_owned(),
    }
}
