//! The native engine's model: one streamed Messages API call per step,
//! through the team subrouter by default (`OPTCHAT_ANTHROPIC_BASE_URL`).
//! Rust has no official Anthropic SDK, so this is raw HTTP, like the
//! compactor's client in optchat-host.

use std::io::BufReader;
use std::time::Duration;

use serde_json::Value;

const API_VERSION: &str = "2023-06-01";
/// The beta that enables server-side `fallbacks: "default"`.
pub const SERVER_FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
/// A stream that sends nothing for this long is stalled (a step that thinks
/// for minutes still streams pings and deltas).
const IDLE: Duration = Duration::from_secs(180);
/// How much of an error body a failure keeps.
const ERROR_BODY: usize = 600;

/// Why a call failed, and whether trying again can help.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CallError {
    pub message: String,
    /// A transport failure, a 429, a 5xx or an overload: worth a retry.
    pub retry: bool,
}

/// One Messages API call: the request body in, the whole response message out.
pub trait ChatModel: Send + Sync {
    fn send(&self, body: &Value) -> Result<Value, CallError>;
}

pub struct HttpModel {
    agent: ureq::Agent,
    url: String,
    key: String,
    beta: Option<&'static str>,
}

impl HttpModel {
    /// `base_url` without `/v1/messages`; `key` goes in `x-api-key`.
    pub fn new(base_url: &str, key: String, server_fallback: bool) -> HttpModel {
        HttpModel {
            agent: ureq::AgentBuilder::new()
                .timeout_connect(Duration::from_secs(30))
                .timeout_read(IDLE)
                .build(),
            url: format!("{}/v1/messages", base_url.trim_end_matches('/')),
            key,
            beta: server_fallback.then_some(SERVER_FALLBACK_BETA),
        }
    }
}

impl ChatModel for HttpModel {
    fn send(&self, body: &Value) -> Result<Value, CallError> {
        let mut request = self
            .agent
            .post(&self.url)
            .set("x-api-key", &self.key)
            .set("anthropic-version", API_VERSION)
            .set(optchat_host::AGENT_HEADER.0, optchat_host::AGENT_HEADER.1);
        if let Some(beta) = self.beta {
            request = request.set("anthropic-beta", beta);
        }
        let response = match request.send_json(body) {
            Ok(r) => r,
            Err(ureq::Error::Status(code, r)) => {
                let text = r.into_string().unwrap_or_default();
                return Err(CallError {
                    message: format!(
                        "HTTP {code}: {}",
                        optchat_core::cut_at_bytes(&text, ERROR_BODY)
                    ),
                    retry: code == 429 || code >= 500,
                });
            }
            Err(e) => {
                return Err(CallError {
                    message: e.to_string(),
                    retry: true,
                });
            }
        };
        let streamed = response.content_type() == "text/event-stream";
        let reader = BufReader::new(response.into_reader());
        let message = if streamed {
            super::sse::read(reader)
        } else {
            serde_json::from_reader::<_, Value>(reader)
                .map_err(|e| format!("bad response body: {e}"))
        };
        // A stream cut by the network or an overload event is transient.
        message.map_err(|message| CallError {
            retry: true,
            message,
        })
    }
}
