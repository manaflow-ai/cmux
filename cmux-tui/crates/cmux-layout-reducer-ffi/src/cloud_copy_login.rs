//! `cmux-cloud-start-core`'s harness login copy over the JSON channel (`cloud_copy_login_*`): the
//! app holds the copy's state between calls, sends it with each event, its monotonic clock and the
//! account and team it has now, and runs the effects the answer lists. The other ops are the
//! copy's rules the app's sign-in and Keychain read ask on their own.

use cmux_cloud_start_core::copy_login::{self, Event, Provider, Scope, ScopeRead, State, gate};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_copy_login_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Step {
    #[serde(default)]
    state: Option<State>,
    event: Event,
    now: u64,
    #[serde(default)]
    scope: Scope,
}

#[derive(Deserialize)]
struct Bytes {
    #[serde(default)]
    provider: Option<Provider>,
    data: Vec<u8>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeychainName {
    provider: Provider,
    #[serde(default)]
    team_id: Option<String>,
    user_id: String,
    #[serde(default)]
    machine_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Scopes {
    provider: Provider,
    #[serde(default)]
    team_id: Option<String>,
    #[serde(default)]
    other_teams: Vec<Option<String>>,
}

#[derive(Deserialize)]
struct Pick {
    reads: Vec<ScopeRead>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Gate {
    #[serde(default)]
    dogfood: bool,
    #[serde(default)]
    remote_switch: Option<bool>,
    #[serde(default)]
    consent: Option<bool>,
    #[serde(default)]
    claude: bool,
    #[serde(default)]
    automatic: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Creator {
    #[serde(default)]
    creator_team_guest: bool,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // One event: the next state and the effects to run, in order.
        b"cloud_copy_login_step" => {
            let step: Step = read(request)?;
            serde_json::to_value(copy_login::step(
                step.state.unwrap_or_default(),
                step.event,
                step.now,
                &step.scope,
            ))
            .map_err(|_| ERR_INVALID)?
        }
        b"cloud_copy_login_validate" => {
            let bytes: Bytes = read(request)?;
            let provider = bytes.provider.ok_or(ERR_INVALID)?;
            json!({ "valid": copy_login::validate(&bytes.data, provider) })
        }
        // The one token `claude setup-token` printed into its capture; null when not exactly one.
        b"cloud_copy_login_claude_token" => {
            let bytes: Bytes = read(request)?;
            json!({ "token": copy_login::claude_token(&bytes.data) })
        }
        b"cloud_copy_login_envelope" => {
            let bytes: Bytes = read(request)?;
            json!({ "credential": copy_login::envelope(&bytes.data) })
        }
        b"cloud_copy_login_keychain_name" => {
            let name: KeychainName = read(request)?;
            json!({ "name": copy_login::keychain_name(
                name.provider,
                name.team_id.as_deref(),
                &name.user_id,
                name.machine_id.as_deref(),
            ) })
        }
        b"cloud_copy_login_scopes" => {
            let scopes: Scopes = read(request)?;
            json!({ "scopes": copy_login::login_scopes(
                scopes.provider,
                scopes.team_id.as_deref(),
                &scopes.other_teams,
            ) })
        }
        b"cloud_copy_login_pick" => {
            let pick: Pick = read(request)?;
            let picked = copy_login::pick_cached(&pick.reads);
            json!({ "pick": picked, "cached": copy_login::cached_login(&picked) })
        }
        b"cloud_copy_login_gate" => {
            let g: Gate = read(request)?;
            json!({
                "stillAllowed": gate::still_allowed(g.dogfood, g.remote_switch, g.consent),
                "copy": gate::copy_allowed(g.dogfood, g.remote_switch, g.consent),
                "recovery": gate::recovery_allowed(g.dogfood, g.claude, g.automatic, g.remote_switch, g.consent),
            })
        }
        b"cloud_copy_login_restart_guest_check" => {
            let creator: Creator = read(request)?;
            json!({ "check": copy_login::restart_guest_check(creator.creator_team_guest) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
