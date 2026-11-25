//! `cmux-cloud-machine` over the JSON channel: the Cloud machine record and its rules
//! (`cloud_machine_*`) and the small Cloud API models (`cloud_model_*`). The app hands over a
//! server's answer or its own records, and acts on the answer; it holds the sockets, timers and
//! HTTP calls itself.

use cmux_cloud_machine::record::{self, Machine, Operation, Status};
use cmux_cloud_machine::{
    cap, changes, error, github, harness_copy, limits, list_facts, models, preview, push, rules,
    vm_host,
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's: `cloud_model_*`, and `cloud_machine_*` but for
/// `cloud_bootstrap`'s `cloud_machine_config_*` and `cloud_machine_step_*`.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_model_")
        || (operation.starts_with(b"cloud_machine_")
            && !operation.starts_with(b"cloud_machine_config_")
            && !operation.starts_with(b"cloud_machine_step_"))
}

fn read<T: DeserializeOwned>(request: &[u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

/// The pending overlay's state and one machine, the shape of every `cloud_machine_changes_*`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChangesRequest {
    #[serde(default)]
    state: changes::Changes,
    #[serde(default)]
    machine: String,
    #[serde(default)]
    id: String,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // What the app reads off one record.
        b"cloud_machine_facts" => {
            #[derive(Deserialize)]
            struct Request {
                machine: Machine,
                #[serde(default)]
                user: Option<String>,
            }
            let request: Request = read(request)?;
            json!(record::facts(&request.machine, request.user.as_deref()))
        }
        // Which statuses are live and which are a change on its way; the app keeps the table.
        b"cloud_machine_statuses" => {
            let words = |pick: fn(Status) -> bool| {
                Status::ALL.into_iter().filter(|status| pick(*status)).collect::<Vec<_>>()
            };
            json!({"live": words(Status::is_live), "changing": words(Status::is_changing), "operations": Operation::ALL})
        }
        b"cloud_machine_listed" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                record: Machine,
                current: Machine,
                connected_since_read: bool,
            }
            let request: Request = read(request)?;
            json!({"machine": rules::listed(&request.record, &request.current, request.connected_since_read)})
        }
        b"cloud_machine_edge" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                record: Machine,
                previous: Status,
                was_resuming: bool,
                connected: bool,
            }
            let request: Request = read(request)?;
            json!({"edge": rules::edge(&request.record, request.previous, request.was_resuming, request.connected)})
        }
        b"cloud_machine_holds_connect" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                machine: Machine,
                origin: rules::Origin,
                app_link: bool,
            }
            let request: Request = read(request)?;
            json!({"holds": rules::holds_connect(&request.machine, request.origin, request.app_link)})
        }
        b"cloud_machine_kept_for_pin" => {
            #[derive(Deserialize)]
            struct Request {
                machines: Vec<Machine>,
                listed: Vec<String>,
            }
            let request: Request = read(request)?;
            json!({"ids": rules::kept_for_pin(&request.machines, &request.listed)})
        }
        b"cloud_machine_plan_entry" => {
            #[derive(Deserialize)]
            struct Request {
                machine: Machine,
                connected: bool,
                #[serde(default)]
                chats: Option<i64>,
            }
            let request: Request = read(request)?;
            json!({"entry": rules::start_chat_plan_entry(&request.machine, request.connected, request.chats)})
        }
        b"cloud_machine_default_name" => {
            #[derive(Deserialize)]
            struct Request {
                taken: Vec<String>,
                candidates: Vec<String>,
            }
            let request: Request = read(request)?;
            json!({"name": rules::default_name(&request.taken, &request.candidates)})
        }
        // The Pause, Resume and Kill overlay: each answers the new state.
        b"cloud_machine_changes_begin" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(flatten)]
                base: ChangesRequest,
                change: Status,
                #[serde(default)]
                baseline: Option<Machine>,
            }
            let Request { base: ChangesRequest { mut state, machine, id }, change, baseline } =
                read(request)?;
            let shown = state.begin(&machine, change, &id, baseline.as_ref());
            json!({"state": state, "shown": shown})
        }
        b"cloud_machine_changes_returned" => {
            let ChangesRequest { mut state, machine, id } = read(request)?;
            state.returned(&machine, &id);
            json!({"state": state})
        }
        b"cloud_machine_changes_rollback" => {
            let ChangesRequest { mut state, machine, id } = read(request)?;
            let rolled_back = state.rolled_back(&machine, &id);
            let shown = state.shown(&machine);
            json!({"state": state, "rolledBack": rolled_back, "shown": shown})
        }
        b"cloud_machine_changes_read_issued" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                state: changes::Changes,
                read: i64,
            }
            let Request { mut state, read: ticket } = read(request)?;
            state.read_issued(ticket);
            json!({"state": state})
        }
        b"cloud_machine_changes_apply" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                state: changes::Changes,
                record: Machine,
                #[serde(default)]
                read: Option<i64>,
            }
            let Request { mut state, record, read: ticket } = read(request)?;
            let shown = state.apply(&record, ticket);
            json!({"state": state, "record": shown})
        }
        b"cloud_machine_changes_removed" => {
            let ChangesRequest { mut state, machine, .. } = read(request)?;
            state.removed(&machine);
            json!({"state": state})
        }
        b"cloud_machine_changes_unsettled" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                state: changes::Changes,
                list: Vec<Machine>,
                #[serde(default)]
                pushed: Vec<String>,
            }
            let request: Request = read(request)?;
            json!({"machines": request.state.unsettled(&request.list, &request.pushed)})
        }
        b"cloud_machine_changes_next_delay" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                delay_ms: u64,
                listed: bool,
            }
            let request: Request = read(request)?;
            json!({"delayMs": changes::next_delay(request.delay_ms, request.listed), "settleDelayMs": changes::SETTLE_DELAY_MS})
        }
        // The pushed state's rules; the app holds the sockets.
        b"cloud_machine_push_url" => {
            #[derive(Deserialize)]
            struct Request {
                base: String,
                machine: String,
            }
            let request: Request = read(request)?;
            json!({"url": push::state_url(&request.base, &request.machine)})
        }
        b"cloud_machine_push_keeps" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                last: Option<Machine>,
                incoming: Machine,
            }
            let request: Request = read(request)?;
            json!({"keeps": push::keeps_listed(request.last.as_ref(), &request.incoming)})
        }
        b"cloud_machine_push_frame" => {
            #[derive(Deserialize)]
            struct Request {
                machine: String,
                text: String,
                #[serde(default)]
                last: Option<Machine>,
            }
            let request: Request = read(request)?;
            json!(push::frame(&request.machine, &request.text, request.last.as_ref()))
        }
        b"cloud_machine_push_handed_off" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                reply: Option<Value>,
            }
            let request: Request = read(request)?;
            json!({"handedOff": push::handed_off(request.reply.as_ref())})
        }
        b"cloud_machine_push_backoff" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                current_ms: Option<u64>,
                opened: bool,
            }
            let request: Request = read(request)?;
            let (wait, next) =
                push::backoff(request.current_ms.unwrap_or(push::FIRST_BACKOFF_MS), request.opened);
            json!({"waitMs": wait, "nextMs": next, "keepaliveMs": push::KEEPALIVE_MS, "ping": push::PING})
        }
        // The machine cap card.
        b"cloud_machine_cap_refusal" => {
            #[derive(Deserialize)]
            struct Request {
                code: String,
                #[serde(default)]
                details: Option<Value>,
            }
            let request: Request = read(request)?;
            json!({"cap": cap::refusal(&request.code, request.details.as_ref())})
        }
        b"cloud_machine_cap_plan" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                free_plan: bool,
                pause_frees: bool,
                machines: Vec<Machine>,
                #[serde(default)]
                user: Option<String>,
            }
            let request: Request = read(request)?;
            json!(cap::plan(
                request.free_plan,
                request.pause_frees,
                &request.machines,
                request.user.as_deref()
            ))
        }
        b"cloud_machine_cap_made_room" => {
            #[derive(Deserialize)]
            struct Request {
                answer: Value,
            }
            let request: Request = read(request)?;
            json!({"machine": cap::made_room(&request.answer)})
        }
        b"cloud_machine_limits_pays" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                plan_id: Option<String>,
                #[serde(default)]
                max_active_vms: Option<i64>,
            }
            let request: Request = read(request)?;
            json!({"pays": limits::pays_for_cloud(request.plan_id.as_deref(), request.max_active_vms)})
        }
        b"cloud_machine_list_facts" => {
            let inputs: list_facts::Inputs = read(request)?;
            json!(list_facts::facts(&inputs))
        }
        // A server's answer as the app's JSON, by kind (`models::KINDS`).
        b"cloud_model_read" => {
            #[derive(Deserialize)]
            struct Request {
                kind: String,
                value: Value,
            }
            let request: Request = read(request)?;
            match models::read(&request.kind, &request.value) {
                Ok(value) => json!({"value": value}),
                Err(error) => json!({"error": error}),
            }
        }
        b"cloud_model_api_error" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                status: i64,
                body: String,
                #[serde(default)]
                header_code: Option<String>,
            }
            let request: Request = read(request)?;
            json!({"error": error::from_response(request.status, request.body.as_bytes(), request.header_code.as_deref())})
        }
        b"cloud_model_api_error_text" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                error: error::ApiError,
                trace_format: String,
            }
            let request: Request = read(request)?;
            json!({"text": error::text(&request.error, &request.trace_format), "code": error::code(&request.error)})
        }
        b"cloud_model_provisioned_api_fields" => {
            #[derive(Deserialize)]
            struct Request {
                api: models::ProvisionedApi,
            }
            let request: Request = read(request)?;
            json!({"fields": models::provisioned_api_fields(&request.api)})
        }
        b"cloud_model_github_status" => {
            #[derive(Deserialize)]
            struct Request {
                status: u16,
                body: String,
            }
            let request: Request = read(request)?;
            json!({"status": github::status(request.status, request.body.as_bytes())})
        }
        b"cloud_model_github_path" => {
            #[derive(Deserialize)]
            struct Request {
                team: String,
            }
            let request: Request = read(request)?;
            json!({"path": github::path(&request.team)})
        }
        b"cloud_model_harness_copy_current" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                #[serde(default)]
                enabled: Option<bool>,
                ttl_seconds: i64,
                age_ms: i64,
            }
            let request: Request = read(request)?;
            json!({"enabled": harness_copy::current(request.enabled, request.ttl_seconds, request.age_ms)})
        }
        b"cloud_model_preview_url" => {
            #[derive(Deserialize)]
            struct Request {
                url: String,
                // Swift's `browserURL(path: "/")` opens the root when no path is given.
                #[serde(default)]
                path: Option<String>,
            }
            let request: Request = read(request)?;
            let path = request.path.as_deref().unwrap_or("/");
            json!({"url": preview::browser_url(&request.url, path)})
        }
        b"cloud_model_vm_host_command" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                on: Option<bool>,
            }
            let request: Request = read(request)?;
            json!({"command": vm_host::command(request.on), "timeoutMs": vm_host::TIMEOUT_MS})
        }
        b"cloud_model_vm_host_answer" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                exit_code: i64,
                stdout: String,
                stderr: String,
            }
            let request: Request = read(request)?;
            match vm_host::parse(request.exit_code, &request.stdout) {
                Some(state) => json!({"state": state}),
                None => {
                    json!({"failure": vm_host::failure(request.exit_code, &request.stdout, &request.stderr)})
                }
            }
        }
        b"cloud_model_vm_host_stale" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                known: bool,
                #[serde(default)]
                failed_age_ms: Option<u64>,
            }
            let request: Request = read(request)?;
            json!({"stale": vm_host::stale(request.known, request.failed_age_ms)})
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
