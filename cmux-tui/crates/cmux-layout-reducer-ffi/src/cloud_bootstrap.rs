//! `cmux-cloud-start-core`'s machine bootstrap, `.cmux/machine.toml` applier and create retry
//! rules over the JSON channel (`cloud_bootstrap_*`, `cloud_machine_config_*`,
//! `cloud_machine_step_outcome`, `cloud_machine_repo_*`, `cloud_create_*`, `cloud_power_retries`). The app makes the file
//! writes and execs a plan lists, sends each exec's answer back and acts on what comes back.

use cmux_cloud_start_core::{
    machine_bootstrap as bootstrap, machine_config as config, machine_create as create,
    machine_repo as repo,
};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    [
        &b"cloud_bootstrap_"[..],
        b"cloud_machine_config_",
        b"cloud_machine_step_",
        b"cloud_machine_repo_",
        b"cloud_create_",
        b"cloud_power_",
    ]
    .iter()
    .any(|prefix| operation.starts_with(prefix))
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The paths, limits and fixed texts the app shows or compares.
        b"cloud_bootstrap_facts" => json!({
            "directory": bootstrap::DIRECTORY,
            "logPath": bootstrap::log_path(),
            "statusPath": bootstrap::status_path(),
            "maxBytes": bootstrap::MAX_BYTES,
            "noScript": bootstrap::NO_SCRIPT,
            "user": bootstrap::USER,
            "waitCommand": bootstrap::wait_command(),
            "configDirectory": config::DIRECTORY,
            "configStatusPath": config::status_path(),
            "configLogPath": config::log_path(),
            "configMaxBytes": config::MAX_BYTES,
        }),
        b"cloud_bootstrap_start_plan" => {
            let request: bootstrap::StartRequest = read(request)?;
            json!(bootstrap::start_plan(&request))
        }
        b"cloud_bootstrap_wait_next" => {
            let request: bootstrap::WaitRead = read(request)?;
            json!(bootstrap::wait_next(&request))
        }
        b"cloud_machine_config_plan" => {
            let request: config::ApplyRequest = read(request)?;
            json!(config::apply_plan(&request))
        }
        // After one exec of a plan: go on (no outcome) or end with this one.
        b"cloud_machine_step_outcome" => {
            #[derive(Deserialize)]
            struct Request {
                answer: bootstrap::ExecAnswer,
                #[serde(default)]
                said: Vec<String>,
            }
            let request: Request = read(request)?;
            json!({ "outcome": bootstrap::step_outcome(&request.answer, &request.said) })
        }
        // A `--repo` spec: the repository with everything the app shows of it, or why it is none.
        b"cloud_machine_repo_parse" => {
            #[derive(Deserialize)]
            struct Request {
                spec: String,
            }
            let request: Request = read(request)?;
            match repo::parse(&request.spec) {
                Ok(parsed) => json!({ "repo": repo::describe(&parsed) }),
                Err(invalid) => json!({ "invalid": invalid }),
            }
        }
        b"cloud_machine_repo_describe" => {
            let request: repo::Repo = read(request)?;
            json!(repo::describe(&request))
        }
        b"cloud_machine_repo_is_ref" => {
            #[derive(Deserialize)]
            struct Request {
                r#ref: String,
            }
            let request: Request = read(request)?;
            json!({ "isRef": repo::is_ref(&request.r#ref) })
        }
        b"cloud_create_definitive_refusal" => {
            #[derive(Deserialize)]
            struct Request {
                code: String,
            }
            let request: Request = read(request)?;
            json!({ "definitive": create::is_definitive_refusal(&request.code) })
        }
        b"cloud_create_team" => {
            let request: create::TeamRequest = read(request)?;
            json!({ "team": create::create_team(&request) })
        }
        b"cloud_power_retries" => {
            #[derive(Deserialize)]
            struct Request {
                code: String,
                attempt: u32,
                attempts: u32,
            }
            let request: Request = read(request)?;
            json!({ "retries": create::power_retries(&request.code, request.attempt, request.attempts) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
