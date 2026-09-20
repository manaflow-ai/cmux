use libp2p::{request_response, StreamProtocol};
use serde::{Deserialize, Serialize};
use std::time::Duration;

pub const PROTOCOL: StreamProtocol = StreamProtocol::new("/cmux/transport/3/relay-auth");

/// Source identity is obtained from libp2p, never from the request.
#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Reserve {
        team: String,
        grant: String,
    },
    Connect {
        team: String,
        destination: String,
        grant: String,
    },
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Response {
    Accepted,
    Denied,
}

pub type Behaviour = request_response::json::Behaviour<Request, Response>;

pub fn behaviour() -> Behaviour {
    Behaviour::with_codec(
        request_response::json::codec::Codec::default()
            .set_request_size_maximum(12 * 1024)
            .set_response_size_maximum(1024),
        [(PROTOCOL, request_response::ProtocolSupport::Full)],
        request_response::Config::default()
            .with_request_timeout(Duration::from_secs(5))
            .with_max_concurrent_streams(64),
    )
}
