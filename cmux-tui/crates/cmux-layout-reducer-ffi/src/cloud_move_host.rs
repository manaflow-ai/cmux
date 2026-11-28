//! `cmux-cloud-start-core::moves::host` over the JSON channel (ops `cloud_move_host_*`): the app's
//! side of the chat place controls. The app reads its tabs, turn states, drafts, ledgers and
//! machines; here is which chats the place actions list and may move, what a chat carries, the
//! own-VM facts and a run's refusal.

use cmux_cloud_start_core::moves::{host, ledger};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's (`cloud_move` leaves `cloud_move_host_*` to it).
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_move_host_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

fn to_value<T: serde::Serialize>(value: T) -> Result<Value, i32> {
    serde_json::to_value(value).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        b"cloud_move_host_eligible" => {
            #[derive(Deserialize)]
            struct Request {
                /// The moved-chat ledger's entries (`cloud_move_moved_chats` `all`).
                #[serde(default)]
                moved: Vec<ledger::Moved>,
                host: String,
                session: String,
                #[serde(default)]
                local: bool,
            }
            let request: Request = read(request)?;
            json!({ "eligible": host::eligible(&request.host, &request.session, request.local, &request.moved) })
        }
        b"cloud_move_host_chats" => {
            #[derive(Deserialize)]
            struct Request {
                /// The moved-chat ledger's entries (`cloud_move_moved_chats` `all`).
                #[serde(default)]
                moved: Vec<ledger::Moved>,
                #[serde(default)]
                tabs: Vec<host::Tab>,
            }
            let request: Request = read(request)?;
            json!({ "chats": to_value(host::chats(&request.tabs, &request.moved))? })
        }
        b"cloud_move_host_sessions" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                moved: Vec<ledger::Moved>,
            }
            let request: Request = read(request)?;
            json!({ "sessions": host::cloud_sessions(&request.moved) })
        }
        b"cloud_move_host_own_facts" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                /// The moved-chat ledger's entries (`cloud_move_moved_chats` `all`).
                #[serde(default)]
                moved: Vec<ledger::Moved>,
                session: String,
                #[serde(default)]
                last_machine: Option<String>,
                #[serde(default)]
                machines: Vec<host::MachineStatus>,
            }
            let request: Request = read(request)?;
            to_value(host::own_facts(
                &request.session,
                &request.moved,
                request.last_machine.as_deref(),
                &request.machines,
            ))?
        }
        b"cloud_move_host_cargo" => {
            let facts: host::CargoFacts = read(request)?;
            to_value(host::cargo(&facts))?
        }
        b"cloud_move_host_run_refusal" => {
            let facts: host::RunFacts = read(request)?;
            json!({ "refusal": host::run_refusal(&facts) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
