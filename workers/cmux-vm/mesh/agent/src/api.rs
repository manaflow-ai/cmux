//! The cmux VM API calls the agent makes: device enrollment and the peer map.

use std::fmt;
use std::net::Ipv4Addr;
use std::time::Duration;

use serde::{Deserialize, Serialize};

const HTTP_TIMEOUT: Duration = Duration::from_secs(30);

/// An API failure: the Worker's `{"_tag","message"}` body, or a transport
/// error (`tag` = `Transport`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiError {
    pub status: Option<u16>,
    pub tag: String,
    pub message: String,
}

impl fmt::Display for ApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.tag, self.message)
    }
}

impl ApiError {
    fn local(tag: &str, message: impl Into<String>) -> Self {
        Self { status: None, tag: tag.into(), message: message.into() }
    }
}

/// Validate an API base URL: https, or http only to 127.0.0.1 or localhost.
/// Returns it without a trailing slash.
pub fn validate_base(url: &str) -> Result<String, ApiError> {
    let url = url.trim().trim_end_matches('/');
    let (scheme, rest) = url
        .split_once("://")
        .ok_or_else(|| ApiError::local("InvalidApiUrl", format!("not a URL: {url:?}")))?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = match host.rsplit_once(':') {
        Some((name, port)) if port.chars().all(|c| c.is_ascii_digit()) => name,
        _ => host,
    };
    if host.is_empty() || authority.contains('@') {
        return Err(ApiError::local("InvalidApiUrl", format!("bad host in {url:?}")));
    }
    match scheme {
        "https" => Ok(url.to_string()),
        "http" if host == "127.0.0.1" || host == "localhost" => Ok(url.to_string()),
        _ => Err(ApiError::local(
            "InvalidApiUrl",
            "the API URL must be https (http only for 127.0.0.1 or localhost)",
        )),
    }
}

/// The API base from `--api` or `CMUX_VM_API_URL`.
pub fn api_base(flag: Option<&str>) -> Result<String, ApiError> {
    let url = match flag {
        Some(url) => url.to_string(),
        None => std::env::var("CMUX_VM_API_URL")
            .map_err(|_| ApiError::local("MissingApiUrl", "set CMUX_VM_API_URL or pass --api"))?,
    };
    validate_base(&url)
}

/// The bearer token from `CMUX_VM_API_KEY`.
pub fn api_key() -> Result<String, ApiError> {
    match std::env::var("CMUX_VM_API_KEY") {
        Ok(key) if !key.trim().is_empty() => Ok(key.trim().to_string()),
        _ => Err(ApiError::local("MissingApiKey", "set CMUX_VM_API_KEY")),
    }
}

/// A public id such as `mesh_…` or `dev_…`: the prefix, then URL-safe
/// characters only, so it can go into a path unescaped.
pub fn check_id(id: &str, prefix: &str) -> Result<(), ApiError> {
    let ok = id.strip_prefix(prefix).is_some_and(|rest| {
        !rest.is_empty() && rest.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    });
    if ok {
        Ok(())
    } else {
        Err(ApiError::local("InvalidId", format!("expected a {prefix}… id, got {id:?}")))
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(HTTP_TIMEOUT).build()
}

fn finish(result: Result<ureq::Response, ureq::Error>, expected: u16) -> Result<String, ApiError> {
    match result {
        Ok(response) => {
            let status = response.status();
            let body = response
                .into_string()
                .map_err(|error| ApiError::local("Transport", error.to_string()))?;
            if status == expected { Ok(body) } else { Err(error_from_body(status, &body)) }
        }
        Err(ureq::Error::Status(status, response)) => {
            let body = response.into_string().unwrap_or_default();
            Err(error_from_body(status, &body))
        }
        Err(ureq::Error::Transport(error)) => Err(ApiError::local("Transport", error.to_string())),
    }
}

fn error_from_body(status: u16, body: &str) -> ApiError {
    #[derive(Deserialize)]
    struct Tagged {
        #[serde(rename = "_tag")]
        tag: String,
        #[serde(default)]
        message: String,
    }
    match serde_json::from_str::<Tagged>(body) {
        Ok(tagged) => ApiError { status: Some(status), tag: tagged.tag, message: tagged.message },
        Err(_) => ApiError {
            status: Some(status),
            tag: format!("Http{status}"),
            message: body.chars().take(500).collect(),
        },
    }
}

/// `POST {base}/v1/meshes/{meshId}/devices`; returns the 201 body.
pub fn enroll_device(
    base: &str,
    key: &str,
    mesh_id: &str,
    name: &str,
    wg_public_key: &str,
) -> Result<String, ApiError> {
    check_id(mesh_id, "mesh_")?;
    let url = format!("{base}/v1/meshes/{mesh_id}/devices");
    let result = agent()
        .post(&url)
        .set("authorization", &format!("Bearer {key}"))
        .send_json(serde_json::json!({ "name": name, "wgPublicKey": wg_public_key }));
    finish(result, 201)
}

/// `GET {base}/v1/devices/{deviceId}/peers`; returns the 200 body.
pub fn fetch_peers(base: &str, key: &str, device_id: &str) -> Result<String, ApiError> {
    check_id(device_id, "dev_")?;
    let url = format!("{base}/v1/devices/{device_id}/peers");
    let result = agent().get(&url).set("authorization", &format!("Bearer {key}")).call();
    finish(result, 200)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PeerMap {
    pub device_id: String,
    pub mesh_id: String,
    pub acl_version: u64,
    pub peers: Vec<Peer>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Peer {
    pub kind: String,
    pub id: String,
    pub address: String,
    #[serde(default)]
    pub allow: Vec<serde_json::Value>,
}

pub fn parse_peers(body: &str) -> Result<PeerMap, ApiError> {
    serde_json::from_str(body)
        .map_err(|error| ApiError::local("InvalidResponse", error.to_string()))
}

/// A `<peer>` argument: an IPv4 address, or an id looked up in the peer map.
pub fn resolve_peer(arg: &str, peers: Option<&PeerMap>) -> Result<Ipv4Addr, ApiError> {
    if let Ok(address) = arg.parse::<Ipv4Addr>() {
        return Ok(address);
    }
    let map = peers
        .ok_or_else(|| ApiError::local("UnknownPeer", format!("{arg:?} is not an IPv4 address")))?;
    let peer =
        map.peers.iter().find(|peer| peer.id == arg).ok_or_else(|| {
            ApiError::local("UnknownPeer", format!("{arg:?} is not in the peer map"))
        })?;
    peer.address.parse().map_err(|_| {
        ApiError::local("InvalidResponse", format!("peer {arg} has a non-IPv4 address"))
    })
}
