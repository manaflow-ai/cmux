//! `cmux-cloud-config` over the JSON channel: which Cloud the app talks to
//! (`cloud_config_*`), the auth rules around its Keychain I/O (`cloud_auth_*`),
//! the install identity's rules (`cloud_identity_*`) and the VM agent-key mint
//! (`cloud_vm_agent_key_*`). The app reads its bundle,
//! environment, files and the Keychain, sends the facts and acts on the answer;
//! it does the HTTP call itself.

use std::collections::BTreeMap;

use cmux_cloud_config::{agent_key, auth, config, identity};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    [&b"cloud_config_"[..], b"cloud_auth_", b"cloud_identity_", b"cloud_vm_agent_key_"]
        .iter()
        .any(|prefix| operation.starts_with(prefix))
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The build's Cloud from the runtime selection, with its token store's names.
        b"cloud_config_from_selection" => {
            let inputs: config::Inputs = read(request)?;
            json!(config::from_selection(&inputs))
        }
        // The token store names of a configuration made without a selection (the placeholder).
        b"cloud_config_storage_names" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                bundle_id: Option<String>,
            }
            let request: Request = read(request)?;
            json!(config::storage_names(request.bundle_id.as_deref(), None))
        }
        b"cloud_config_sign_in_url" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                auth_web_origin: String,
                callback_scheme: String,
                state: Option<String>,
            }
            let request: Request = read(request)?;
            json!({ "url": config::sign_in_url(&request.auth_web_origin, &request.callback_scheme, request.state.as_deref()) })
        }
        // How a launch signs in, and which files its account pick reads.
        b"cloud_auth_launch_sign_in" => {
            #[derive(Deserialize)]
            struct Request {
                build: auth::Build,
                environment: BTreeMap<String, String>,
                home: String,
            }
            let request: Request = read(request)?;
            let sign_in = auth::launch_sign_in(&request.build, &request.environment);
            let paths = if sign_in.auto_login {
                auth::credential_paths(&request.environment, &request.home)
            } else {
                Vec::new()
            };
            json!({ "signIn": sign_in, "paths": paths })
        }
        // The account the launch signs in, from the files the app read.
        b"cloud_auth_launch_login" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                sign_in: auth::LaunchSignIn,
                reads: Option<auth::Reads>,
            }
            let request: Request = read(request)?;
            let decision = request.reads.as_ref().map(auth::decide);
            json!(auth::launch_login(&request.sign_in, decision.as_ref()))
        }
        b"cloud_auth_sign_in_window" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                window: auth::SignInWindow,
                default_browser: Option<String>,
            }
            let request: Request = read(request)?;
            json!({ "opensDefaultBrowser": auth::opens_default_browser(request.window, request.default_browser.as_deref()) })
        }
        b"cloud_auth_creation_scope" => {
            #[derive(Deserialize)]
            struct Request {
                previous: Vec<Option<String>>,
                current: Vec<Option<String>>,
            }
            let request: Request = read(request)?;
            json!({ "survives": auth::creation_survives_scope_change(&request.previous, &request.current) })
        }
        b"cloud_auth_seat_facts" => {
            let inputs: auth::SeatInputs = read(request)?;
            json!(auth::seat_facts(&inputs))
        }
        b"cloud_auth_invite_answer" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                error: Option<String>,
                first_failure_already_member: Option<bool>,
            }
            let request: Request = read(request)?;
            json!({ "answer": auth::invite_answer(request.error.as_deref(), request.first_failure_already_member) })
        }
        b"cloud_identity_mint_team" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                requested: Option<String>,
                active_stack_team: Option<String>,
                managed_stack_team: Option<String>,
                stack_project_id: String,
            }
            let request: Request = read(request)?;
            match identity::mint_team(
                request.requested.as_deref(),
                request.active_stack_team.as_deref(),
                request.managed_stack_team.as_deref(),
                &request.stack_project_id,
            ) {
                Ok(team) => json!({ "team": team }),
                Err(refusal) => json!({ "refusal": refusal }),
            }
        }
        // `{user, expiresAt, team}`, each null when absent: `team` is the backend team an
        // install token names, the one `cmux auth token` mints for with no asked or active team.
        b"cloud_identity_token" => {
            #[derive(Deserialize)]
            struct Request {
                token: String,
            }
            let request: Request = read(request)?;
            json!(identity::claims(&request.token))
        }
        b"cloud_identity_check" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                team: Option<String>,
                #[serde(default)]
                refusal_code: Option<String>,
            }
            let request: Request = read(request)?;
            json!({
                "isTeam": request.team.as_deref().map(identity::is_team),
                "transient": request.refusal_code.as_deref().map(identity::is_transient),
            })
        }
        b"cloud_identity_install_key" => {
            #[derive(Deserialize)]
            struct Request {
                user: String,
            }
            let request: Request = read(request)?;
            json!({ "account": identity::install_key_account(&request.user) })
        }
        b"cloud_identity_share_origin" => {
            #[derive(Default, Deserialize)]
            #[serde(default)]
            struct Request {
                url: Option<String>,
                folders: Vec<String>,
            }
            let request: Request = read(request)?;
            json!({
                "origin": request.url.as_deref().and_then(identity::share_origin),
                "folderApis": request.folders.iter().filter_map(|f| identity::share_folder_api(f)).collect::<Vec<_>>(),
            })
        }
        b"cloud_auth_launch_keys" => {
            #[derive(Deserialize)]
            struct Request {
                environment: BTreeMap<String, String>,
            }
            let request: Request = read(request)?;
            json!({ "keys": auth::launch_keys(&request.environment) })
        }
        b"cloud_auth_environment" => {
            #[derive(Deserialize)]
            struct Request {
                process: BTreeMap<String, String>,
                launch: BTreeMap<String, String>,
            }
            let request: Request = read(request)?;
            json!({ "environment": auth::auth_environment(&request.process, &request.launch) })
        }
        b"cloud_auth_credential_paths" => {
            #[derive(Deserialize)]
            struct Request {
                environment: BTreeMap<String, String>,
                home: String,
            }
            let request: Request = read(request)?;
            json!({ "paths": auth::credential_paths(&request.environment, &request.home) })
        }
        b"cloud_auth_credentials" => {
            let reads: auth::Reads = read(request)?;
            json!(auth::decide(&reads))
        }
        b"cloud_auth_mask" => {
            #[derive(Deserialize)]
            struct Request {
                email: String,
            }
            let request: Request = read(request)?;
            json!({ "masked": auth::mask(&request.email) })
        }
        b"cloud_auth_team" => {
            #[derive(Deserialize)]
            struct Request {
                requested: Option<String>,
                resolved: Option<String>,
                #[serde(default)]
                available: Vec<String>,
                managed: Option<String>,
            }
            let request: Request = read(request)?;
            let active = auth::allowed_team_id(
                request.resolved.as_deref(),
                &request.available,
                request.managed.as_deref(),
            );
            let refusal = auth::team_refusal(
                request.requested.as_deref(),
                active.as_deref(),
                request.managed.as_deref(),
            );
            // The account's teams this device may use: only the managed one on a managed device.
            let allowed: Vec<&String> = request
                .available
                .iter()
                .filter(|id| request.managed.as_ref().is_none_or(|managed| managed == *id))
                .collect();
            json!({ "active": active, "refusal": refusal, "allowed": allowed })
        }
        b"cloud_vm_agent_key_request" => {
            #[derive(Deserialize)]
            struct Request {
                backend: config::Backend,
                #[serde(default)]
                params: Map<String, Value>,
            }
            let request: Request = read(request)?;
            match agent_key::request(&request.backend, &request.params) {
                Ok(request) => json!({ "request": request }),
                Err(refusal) => json!({ "refusal": refusal }),
            }
        }
        b"cloud_vm_agent_key_answer" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                status: u16,
                #[serde(default)]
                body: String,
                base_url: String,
                team_id: String,
            }
            let request: Request = read(request)?;
            match agent_key::answer(
                request.status,
                request.body.as_bytes(),
                &request.base_url,
                &request.team_id,
            ) {
                Ok(fields) => json!({ "result": fields }),
                Err(refusal) => json!({ "refusal": refusal }),
            }
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
