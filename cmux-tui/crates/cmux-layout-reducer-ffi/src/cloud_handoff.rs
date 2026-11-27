//! `cmux-cloud-config`'s consent session handoff over the JSON channel (`cloud_handoff_*`): whether a
//! signed-out build asks cmux NIGHTLY for a session, NIGHTLY's refusal or consent alert for one
//! `auth.session.request`, and the web route call that mints the recipient's session. The app reads
//! the socket peer's uid and signature, shows the alert and makes the HTTP call itself.

use cmux_cloud_config::handoff;
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"cloud_handoff_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer = match operation {
        // Whether a launching build asks NIGHTLY, and how long it waits for the answer.
        b"cloud_handoff_client_asks" => {
            let facts: handoff::ClientFacts = read(request)?;
            json!({
                "asks": handoff::client_asks(&facts),
                "method": handoff::METHOD,
                "timeoutSeconds": handoff::CLIENT_TIMEOUT.as_secs(),
            })
        }
        // NIGHTLY's refusal, or the consent alert to show, for one request.
        b"cloud_handoff_request_answer" => {
            let facts: handoff::RequestFacts = read(request)?;
            json!(handoff::request_answer(&facts))
        }
        // The web route call on "Sign In".
        b"cloud_handoff_mint_request" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Request {
                auth_web_origin: String,
                bundle_id: String,
                #[serde(default)]
                tag: Option<String>,
            }
            let request: Request = read(request)?;
            let recipient = handoff::Recipient { bundle_id: request.bundle_id, tag: request.tag };
            json!(handoff::mint_request(&request.auth_web_origin, &recipient))
        }
        // What the route's HTTP answer means: the socket result or a refusal.
        b"cloud_handoff_mint_answer" => {
            #[derive(Deserialize)]
            struct Request {
                status: u16,
                #[serde(default)]
                body: String,
            }
            let request: Request = read(request)?;
            json!(handoff::mint_answer(request.status, request.body.as_bytes()))
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
