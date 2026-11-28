//! The chat pane's Cloud start wire over the JSON channel (`cloud_pane_*`), from
//! `cmux-cloud-start-core`'s `pane_wire`: the Repick params a pane accepts, the hand-off refusals
//! that keep a chat on this Mac, the clone progress and progress push a pane shows, and the
//! harnesses whose credentials a machine confirms.

use cmux_cloud_start_core::pane_wire;
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_pane_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // The Repick params a pane accepts (raw params in, `{"repick": {machine?, name?}|null}`).
        b"cloud_pane_repick" => {
            let params: serde_json::Value = read(request)?;
            json!({ "repick": pane_wire::repick(&params) })
        }
        // The hand-off refusal code that keeps the chat here, if any.
        b"cloud_pane_refused_here" => {
            #[derive(Deserialize)]
            struct Request {
                #[serde(default)]
                ok: Option<bool>,
                #[serde(default)]
                code: Option<String>,
            }
            let request: Request = read(request)?;
            json!({ "code": pane_wire::refused_here(request.ok, request.code.as_deref()) })
        }
        // A clone's seed progress as the pane's fields.
        b"cloud_pane_seed_fields" => {
            let seed: pane_wire::SeedProgress = read(request)?;
            serde_json::Value::Object(pane_wire::seed_fields(&seed))
        }
        // The progress push a pane shows.
        b"cloud_pane_progress" => {
            let facts: pane_wire::Progress = read(request)?;
            pane_wire::progress(&facts)
        }
        // The harnesses whose credentials a machine confirms (null: it confirms none).
        b"cloud_pane_credential_harnesses" => {
            #[derive(Deserialize)]
            struct Request {
                supported: bool,
                capabilities: Vec<String>,
                subscription: bool,
            }
            let request: Request = read(request)?;
            let harnesses = pane_wire::credential_harnesses(
                request.supported,
                &request.capabilities,
                request.subscription,
            );
            json!({ "harnesses": harnesses })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
