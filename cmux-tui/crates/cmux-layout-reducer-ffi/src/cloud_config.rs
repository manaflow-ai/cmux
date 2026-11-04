//! `cmux-cloud-config` over the JSON channel: which Cloud the app talks to
//! (`cloud_config_*`), the auth rules around its Keychain I/O (`cloud_auth_*`)
//! and the VM agent-key mint (`cloud_vm_agent_key_*`). The app reads its bundle,
//! environment, files and the Keychain, sends the facts and acts on the answer;
//! it does the HTTP call itself.

use std::collections::BTreeMap;

use cmux_cloud_config::{agent_key, auth, config};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    [&b"cloud_config_"[..], b"cloud_auth_", b"cloud_vm_agent_key_"]
        .iter()
        .any(|prefix| operation.starts_with(prefix))
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WithEnvironment {
    identity: config::Identity,
    #[serde(default)]
    environment: BTreeMap<String, String>,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The build's Cloud, with the names derived from it.
        b"cloud_config_resolve" => {
            let inputs: config::Inputs = read(request)?;
            let configuration = config::resolve(&inputs);
            let identity = configuration.identity();
            json!({
                "configuration": configuration,
                "keychainService": config::keychain_service(&identity),
                "credentialsSubpath": config::credentials_subpath(&identity),
                "vmApiBaseUrl": config::vm_api_base_url(&configuration.backend),
            })
        }
        // The token store's names for facts a caller may have changed after resolving.
        b"cloud_config_names" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                identity: config::Identity,
                #[serde(default)]
                defaults_keys: Vec<String>,
            }
            let request: Request = read(request)?;
            let keys: Map<String, Value> = request
                .defaults_keys
                .iter()
                .map(|key| (key.clone(), json!(config::auth_defaults_key(&request.identity, key))))
                .collect();
            json!({
                "keychainService": config::keychain_service(&request.identity),
                "credentialsSubpath": config::credentials_subpath(&request.identity),
                "defaultsKeys": keys,
            })
        }
        // The APIs that read the launch environment at call time.
        b"cloud_config_apis" => {
            let request: WithEnvironment = read(request)?;
            let (identity, environment) = (&request.identity, &request.environment);
            json!({
                "ownerApi": config::owner_api_base_url(identity, environment),
                "shareApi": config::share_api_base_url(identity, environment),
                "previewApi": config::platform_preview_api_base_url(identity, environment),
                "artifactsApi": config::artifacts_api_base_url(identity, environment),
            })
        }
        b"cloud_config_accepts_share_api" => {
            #[derive(Deserialize)]
            struct Request {
                identity: config::Identity,
                api: String,
            }
            let request: Request = read(request)?;
            json!({ "accepts": config::accepts_share_api(&request.identity, &request.api) })
        }
        b"cloud_config_capture_build" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                bundle_id: Option<String>,
                bench_hooks: bool,
            }
            let request: Request = read(request)?;
            json!({ "capture": config::is_capture_build(request.bundle_id.as_deref(), request.bench_hooks) })
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
            json!({ "active": active, "refusal": refusal })
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
