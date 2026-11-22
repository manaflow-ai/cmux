//! The cmux VM API calls the agent makes: device enrollment (with an API key
//! or a one-time code), key rotation, the peer map and the tunnel config.
//! Without an API key a device authenticates its own requests with its
//! install-key signature (M3).

use std::fmt;
use std::net::Ipv4Addr;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::install::Proof;

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

/// An enrollment code: `mec_` and 26 lowercase Crockford base32 characters.
/// The error never repeats the code.
pub fn check_enroll_code(code: &str) -> Result<(), ApiError> {
    const ALPHABET: &str = "0123456789abcdefghjkmnpqrstvwxyz";
    let ok = code
        .strip_prefix("mec_")
        .is_some_and(|rest| rest.len() == 26 && rest.chars().all(|c| ALPHABET.contains(c)));
    if ok {
        Ok(())
    } else {
        Err(ApiError::local(
            "InvalidEnrollCode",
            "the enroll code is not mec_ followed by 26 lowercase Crockford base32 characters",
        ))
    }
}

/// A device name: one non-empty line (it is a line of the signed message).
pub fn check_device_name(name: &str) -> Result<(), ApiError> {
    if name.is_empty() || name.contains(['\n', '\r']) {
        Err(ApiError::local("InvalidName", "the device name must be one non-empty line"))
    } else {
        Ok(())
    }
}

/// How an enrollment is authorized.
pub enum EnrollAuth<'a> {
    /// `Authorization: Bearer` with an API key.
    ApiKey(&'a str),
    /// A one-time enrollment code in the body; no Authorization header.
    Code(&'a str),
}

/// What an enrollment registers, and its install-key proof.
pub struct Enrollment<'a> {
    pub name: &'a str,
    pub wg_public_key: &'a str,
    pub install_public_key: &'a str,
    pub proof: &'a Proof,
}

/// `POST {base}/v1/meshes/{meshId}/devices` with an API key, or
/// `POST {base}/v1/meshes/{meshId}/device-enrollments` with a code; returns
/// the 201 body.
pub fn enroll_device(
    base: &str,
    auth: EnrollAuth<'_>,
    mesh_id: &str,
    enrollment: &Enrollment<'_>,
) -> Result<String, ApiError> {
    check_id(mesh_id, "mesh_")?;
    check_device_name(enrollment.name)?;
    let mut body = serde_json::json!({
        "name": enrollment.name,
        "wgPublicKey": enrollment.wg_public_key,
        "installPublicKey": enrollment.install_public_key,
        "signedAt": enrollment.proof.signed_at,
        "nonce": enrollment.proof.nonce,
        "signature": enrollment.proof.signature,
    });
    let request = match auth {
        EnrollAuth::ApiKey(key) => agent()
            .post(&format!("{base}/v1/meshes/{mesh_id}/devices"))
            .set("authorization", &format!("Bearer {key}")),
        EnrollAuth::Code(code) => {
            check_enroll_code(code)?;
            body["code"] = serde_json::json!(code);
            agent().post(&format!("{base}/v1/meshes/{mesh_id}/device-enrollments"))
        }
    };
    finish(request.send_json(body), 201)
}

/// `POST {base}/v1/devices/{deviceId}/rotate-key` with an API key, or with no
/// key `POST {base}/v1/devices/{deviceId}/signed/rotate-key`, where the
/// install-key signature in the body is the only credential (M3). Returns the
/// 200 body (a tunnel config with the new server key).
pub fn rotate_key(
    base: &str,
    key: Option<&str>,
    device_id: &str,
    new_public_key: &str,
    proof: &Proof,
) -> Result<String, ApiError> {
    check_id(device_id, "dev_")?;
    let body = serde_json::json!({
        "newPublicKey": new_public_key,
        "signedAt": proof.signed_at,
        "nonce": proof.nonce,
        "signature": proof.signature,
    });
    let request = match key {
        Some(key) => agent()
            .post(&format!("{base}/v1/devices/{device_id}/rotate-key"))
            .set("authorization", &format!("Bearer {key}")),
        None => agent().post(&format!("{base}/v1/devices/{device_id}/signed/rotate-key")),
    };
    finish(request.send_json(body), 200)
}

/// `GET {base}/v1/devices/{deviceId}/peers`; returns the 200 body.
pub fn fetch_peers(base: &str, key: &str, device_id: &str) -> Result<String, ApiError> {
    check_id(device_id, "dev_")?;
    let url = format!("{base}/v1/devices/{device_id}/peers");
    let result = agent().get(&url).set("authorization", &format!("Bearer {key}")).call();
    finish(result, 200)
}

/// `GET {base}/v1/tunnels/{tunnelId}`; returns the 200 body (a tunnel config).
pub fn fetch_tunnel(base: &str, key: &str, tunnel_id: &str) -> Result<String, ApiError> {
    check_id(tunnel_id, "tun_")?;
    let url = format!("{base}/v1/tunnels/{tunnel_id}");
    let result = agent().get(&url).set("authorization", &format!("Bearer {key}")).call();
    finish(result, 200)
}

/// A device's own read without a credential (M3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignedRead {
    /// `POST /v1/devices/{deviceId}/signed/peers`, signed with purpose `peers`.
    Peers,
    /// `POST /v1/devices/{deviceId}/signed/tunnel`, signed with purpose `tunnel`.
    Tunnel,
}

/// `POST {base}/v1/devices/{deviceId}/signed/{peers|tunnel}` with only the
/// install-key proof in the body and no Authorization header; returns the
/// 200 body. The proof must be for the matching purpose, this device as
/// target, an empty WireGuard key and an empty name.
pub fn signed_read(
    base: &str,
    read: SignedRead,
    device_id: &str,
    proof: &Proof,
) -> Result<String, ApiError> {
    check_id(device_id, "dev_")?;
    let path = match read {
        SignedRead::Peers => "peers",
        SignedRead::Tunnel => "tunnel",
    };
    let url = format!("{base}/v1/devices/{device_id}/signed/{path}");
    let result = agent().post(&url).send_json(serde_json::json!({
        "signedAt": proof.signed_at,
        "nonce": proof.nonce,
        "signature": proof.signature,
    }));
    finish(result, 200)
}

/// The bearer token from `CMUX_VM_API_KEY`, or none (then the device signs).
pub fn optional_api_key() -> Option<String> {
    api_key().ok()
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
