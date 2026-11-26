//! `cmux-cloud-start-core`'s Cloud start rules for the app's `CloudStartChat`,
//! `CloudStartSession`, `CloudMachineCreation` and `CloudMachineCreateFlow` over the JSON channel
//! (`cloud_launch_*`): the create gate and params, the approval step machine, the upgrade offer,
//! the idempotency key's bookkeeping, the disk grow steps, and the start-session checks, command,
//! failure kinds, reply and ask cards. The app makes the calls these name.

use cmux_cloud_start_core::{create_flow as create, grow_disk as grow, start_session as session};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_launch_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GateRequest {
    #[serde(default)]
    limits: Option<create::Limits>,
    #[serde(default)]
    makes_room: bool,
}

#[derive(Deserialize)]
struct NameRequest {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct StepRequest {
    state: create::Approval,
    event: create::Event,
}

#[derive(Deserialize)]
struct AttemptRequest {
    attempt: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OfferRequest {
    refusal: create::RefusalInput,
    #[serde(default)]
    plan_required_code: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NeedsRequest {
    script: create::Part,
    machine_config: create::Part,
}

#[derive(Deserialize)]
struct KeyRequest {
    key: create::CreateKey,
    change: create::KeyChange,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PhaseRequest {
    has_session: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GrowRequest {
    sizes: grow::Sizes,
    #[serde(default)]
    answer: Option<grow::Answer>,
    #[serde(default)]
    retried: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FailureRequest {
    #[serde(default)]
    code: Option<String>,
    #[serde(default)]
    message: String,
    folder_needed: String,
    #[serde(default)]
    named: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FolderRequest {
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    has_cwd: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReleaseRequest {
    made: bool,
    strands: bool,
    same_account: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RunKeyRequest {
    #[serde(default)]
    machine_id: Option<String>,
    #[serde(default)]
    name: Option<String>,
}

/// One change to the ask cards; the reply is the new state and the change's answer.
#[derive(Deserialize)]
#[serde(tag = "do", rename_all = "snake_case")]
enum AskChange {
    Begin { tab: String, token: String },
    Deliver { tab: String, dialog: String },
    Settle { tab: String, token: String, answer: session::Answer, same_account: bool },
    Finish { tab: String, token: String },
    Started { tab: String, token: String },
    DoneCardAnswered { tab: String },
    EndAll,
}

#[derive(Deserialize)]
struct AsksRequest {
    #[serde(default)]
    asks: session::Asks,
    change: AskChange,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"cloud_launch_facts" => json!({
            "createOp": create::CREATE_OP,
            "bootOp": create::BOOT_OP,
            "defaultCpu": create::DEFAULT_CPU,
            "defaultMemoryMb": create::DEFAULT_MEMORY_MB,
            "defaultDiskMb": create::DEFAULT_DISK_MB,
            "planRequiredCode": create::PLAN_REQUIRED_CODE,
            "agentMax": session::AGENT_MAX,
            "pathMax": session::PATH_MAX,
            "listFreshMs": session::LIST_FRESH_MS,
            "connectWaitMs": session::CONNECT_WAIT_MS,
            "askWaitMs": session::ASK_WAIT_MS,
            "growStepBytes": grow::STEP_BYTES,
        }),
        b"cloud_launch_gate" => {
            let request: GateRequest = read(request)?;
            json!(create::gate(request.limits.as_ref(), request.makes_room))
        }
        b"cloud_launch_named" => {
            let request: NameRequest = read(request)?;
            json!(create::named(request.name.as_deref()))
        }
        b"cloud_launch_create_params" => {
            let request: create::CreateInput = read(request)?;
            json!(create::create_params(&request))
        }
        b"cloud_launch_approval_step" => {
            let request: StepRequest = read(request)?;
            json!(create::step(request.state, request.event))
        }
        b"cloud_launch_backoff" => {
            let request: AttemptRequest = read(request)?;
            json!({ "ms": create::backoff_ms(request.attempt) })
        }
        b"cloud_launch_pro_offer" => {
            let request: OfferRequest = read(request)?;
            let code = request.plan_required_code.as_deref().unwrap_or(create::PLAN_REQUIRED_CODE);
            json!({ "offer": create::pro_offer(&request.refusal, code) })
        }
        b"cloud_launch_bootstrap_needs" => {
            let request: NeedsRequest = read(request)?;
            json!(create::bootstrap_needs(&request.script, &request.machine_config))
        }
        b"cloud_launch_key_change" => {
            let request: KeyRequest = read(request)?;
            json!(create::change_key(request.key, request.change))
        }
        b"cloud_launch_restart_phase" => {
            let request: PhaseRequest = read(request)?;
            json!({ "phase": create::restart_phase(request.has_session) })
        }
        b"cloud_launch_grow_step" => {
            let request: GrowRequest = read(request)?;
            match &request.answer {
                None => json!(grow::start(&request.sizes)),
                Some(answer) => json!(grow::after(&request.sizes, answer, request.retried)),
            }
        }
        b"cloud_launch_session_request" => {
            let request: session::Invocation = read(request)?;
            match session::request(&request) {
                Ok(run) => json!({ "request": run, "command": session::command(&run) }),
                Err(invalid) => json!({ "invalid": invalid }),
            }
        }
        b"cloud_launch_session_failure" => {
            let request: FailureRequest = read(request)?;
            json!(session::start_failure(
                request.code.as_deref(),
                &request.message,
                &request.folder_needed,
                &request.named,
            ))
        }
        b"cloud_launch_from_folder" => {
            let request: FolderRequest = read(request)?;
            json!(session::from_folder(request.text.as_deref(), request.has_cwd))
        }
        b"cloud_launch_releases" => {
            let request: ReleaseRequest = read(request)?;
            json!({ "releases": session::releases(request.made, request.strands, request.same_account) })
        }
        b"cloud_launch_run_key" => {
            let request: RunKeyRequest = read(request)?;
            json!({ "machine": session::run_key_machine(request.machine_id.as_deref(), request.name.as_deref()) })
        }
        b"cloud_launch_reply" => {
            let request: session::ReplyInput = read(request)?;
            json!(session::reply(&request))
        }
        b"cloud_launch_asks" => {
            let AsksRequest { mut asks, change } = read(request)?;
            let answer = match change {
                AskChange::Begin { tab, token } => json!({ "dialog": asks.begin(&tab, &token) }),
                AskChange::Deliver { tab, dialog } => {
                    json!({ "taken": asks.deliver(&tab, &dialog) })
                }
                AskChange::Settle { tab, token, answer, same_account } => {
                    json!({ "answer": asks.settle(&tab, &token, answer, same_account) })
                }
                AskChange::Finish { tab, token } => json!({ "closed": asks.finish(&tab, &token) }),
                AskChange::Started { tab, token } => {
                    json!({ "closed": asks.started(&tab, &token) })
                }
                AskChange::DoneCardAnswered { tab } => {
                    json!({ "owned": asks.done_card_answered(&tab) })
                }
                AskChange::EndAll => json!({ "end": asks.end_all() }),
            };
            json!({ "asks": asks, "answer": answer, "waiting": asks.waiting() })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(op: &str, body: serde_json::Value) -> serde_json::Value {
        serde_json::from_slice(&respond(op.as_bytes(), body.to_string().as_bytes()).expect(op))
            .unwrap()
    }

    #[test]
    fn ops_answer() {
        assert!(handles(b"cloud_launch_gate"));
        assert!(!handles(b"cloud_start_x"));
        assert_eq!(call("cloud_launch_gate", json!({}))["gate"], "allowed");
        assert_eq!(call("cloud_launch_backoff", json!({"attempt": 0}))["ms"], 250);
        assert_eq!(
            call("cloud_launch_restart_phase", json!({"hasSession": true}))["phase"],
            "created"
        );
        assert_eq!(call("cloud_launch_run_key", json!({"name": "n"}))["machine"], "name:n");
        assert_eq!(
            call(
                "cloud_launch_grow_step",
                json!({"sizes": {"floor": 1, "needed": 1, "maxDisk": 1u64 << 40}})
            )["do"],
            "resize"
        );
        let run = call("cloud_launch_session_request", json!({"agent": "claude", "name": "box"}));
        assert_eq!(run["command"], "cmux cloud start-session --name 'box' --agent claude");
        assert_eq!(
            call("cloud_launch_session_request", json!({"agent": "X"}))["invalid"],
            "agent_invalid"
        );
        let begun =
            call("cloud_launch_asks", json!({"change": {"do": "begin", "tab": "t", "token": "A"}}));
        assert_eq!(begun["answer"]["dialog"], "cloud-start-a");
        assert_eq!(begun["waiting"][0][0], "t");
        assert!(call("cloud_launch_facts", json!({}))["planRequiredCode"].is_string());
        assert_eq!(respond(b"cloud_launch_nope", b"{}"), Err(ERR_INVALID));
        assert_eq!(respond(b"cloud_launch_gate", b"nope"), Err(ERR_INVALID));
    }
}
