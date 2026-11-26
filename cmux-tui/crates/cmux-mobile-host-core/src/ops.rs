//! The app's `mobile_host` requests: one JSON object tagged by `op`, answered with one JSON object.

use crate::credentials::{Credentials, Request};
use crate::{dev_auto_approve, pairing_seed, record_name};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;

/// A request that does not decode.
#[derive(Debug)]
pub struct Error(serde_json::Error);

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "mobile_host request: {}", self.0)
    }
}

impl std::error::Error for Error {}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
enum Op {
    /// One event of a phone credentials state (`state` absent: a fresh one).
    Credentials {
        #[serde(default)]
        state: Option<Credentials>,
        ids: i64,
        event: Event,
    },
    #[serde(rename_all = "camelCase")]
    PairingSeedTrusts {
        seed: Option<String>,
        request: pairing_seed::SeedRequest,
    },
    #[serde(rename_all = "camelCase")]
    DevAutoApprove {
        kind: String,
        bundle_id: Option<String>,
        tag: Option<String>,
        approve_first: Option<String>,
        debug_build: bool,
    },
    #[serde(rename_all = "camelCase")]
    DevRequest {
        kind: String,
        bundle_id: Option<String>,
        mac_dev_tag: Option<String>,
        auto_tag: Option<String>,
        #[serde(default)]
        paired_user_id: String,
        account_user_id: Option<String>,
    },
    RecordName {
        id: String,
    },
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum Event {
    Update { paired: BTreeSet<String>, listed: Option<BTreeSet<String>> },
    Connected,
    Disconnected,
    Reply { id: i64, message: Value },
}

/// Answers one `mobile_host` request.
pub fn respond(request: &[u8]) -> Result<Vec<u8>, Error> {
    let op: Op = serde_json::from_slice(request).map_err(Error)?;
    let reply = match op {
        Op::Credentials { state, mut ids, event } => {
            let mut state = state.unwrap_or_default();
            let requests: Option<Vec<Request>> = match event {
                Event::Update { paired, listed } => Some(state.update(paired, listed, &mut ids)),
                Event::Connected => Some(state.connected(&mut ids)),
                Event::Disconnected => {
                    state.disconnected();
                    Some(Vec::new())
                }
                Event::Reply { id, message } => state.reply(id, &message, &mut ids),
            };
            json!({
                "requests": requests.map(|requests| requests.iter().map(Request::to_json).collect::<Vec<_>>()),
                "ids": ids,
                "tokens": state.tokens(),
                "needsConnection": state.needs_connection(),
                "refused": state.refused,
                "ending": state.ending,
                "state": state,
            })
        }
        Op::PairingSeedTrusts { seed, request } => {
            json!({"trusts": pairing_seed::trusts(seed.as_deref(), &request)})
        }
        Op::DevAutoApprove { kind, bundle_id, tag, approve_first, debug_build } => json!({
            "tag": dev_auto_approve::auto_approve_tag(&kind, bundle_id.as_deref(), tag.as_deref(),
                approve_first.as_deref(), debug_build),
            "devTag": dev_auto_approve::dev_tag(&kind, bundle_id.as_deref(), tag.as_deref()),
        }),
        Op::DevRequest {
            kind,
            bundle_id,
            mac_dev_tag,
            auto_tag,
            paired_user_id,
            account_user_id,
        } => json!({
            "phoneTag": dev_auto_approve::phone_tag(&kind, bundle_id.as_deref()),
            "asksQuietly": dev_auto_approve::asks_quietly(&kind, bundle_id.as_deref(), mac_dev_tag.as_deref()),
            "approves": dev_auto_approve::approves(&kind, bundle_id.as_deref(), auto_tag.as_deref(),
                &paired_user_id, account_user_id.as_deref()),
        }),
        Op::RecordName { id } => json!({"name": record_name::acpmux_record_name(&id)}),
    };
    serde_json::to_vec(&reply).map_err(Error)
}
