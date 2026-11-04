//! Native keys arrive only after the parent can authenticate a child-created socket.

use std::io::{self, Read as _};
use std::os::fd::AsRawFd as _;
use std::os::unix::net::UnixStream;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use zeroize::Zeroizing;

use super::cloud_broker::{Bound, inherited};
use super::dial::DIAL_TIMEOUT;
use super::state::LinkConfig;

pub(super) struct Identity {
    pub config: LinkConfig,
    pub key: Zeroizing<[u8; 32]>,
    pub route: super::native_route::NativeRoute,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Bootstrap {
    version: u8,
    install: String,
    team: String,
    mesh: String,
    tenant: String,
    ipv4_cidr: String,
    device: String,
    tunnel: super::native_route::Tunnel,
    private_key: String,
}

/// `step` names the check, never a value: the app shows the message in `link_route`.
fn refused(step: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("cloud.native.bootstrap_refused: {step}"))
}

/// The inherited pair names the parent, not the child. Return a fresh pair's
/// endpoint over it so the app's kernel peer token names this child on the
/// very descriptor that will receive the Native key and broker replies.
pub(super) fn bind(fd: &str) -> io::Result<Bound> {
    let parent = inherited(fd)?;
    parent.set_write_timeout(Some(DIAL_TIMEOUT))?;
    let (mut stream, app) = UnixStream::pair()?;
    cmux_unix_socket::descriptor::send(&parent, &[1], app.as_raw_fd())?;
    drop(app);
    drop(parent);
    stream.set_read_timeout(Some(DIAL_TIMEOUT))?;
    let identity = read_identity(&mut stream)?;
    stream.set_read_timeout(None)?;
    Ok(Bound { stream, identity: Some(identity) })
}

fn read_identity(stream: &mut UnixStream) -> io::Result<Identity> {
    let deadline = std::time::Instant::now() + DIAL_TIMEOUT;
    let mut bytes = Zeroizing::new(Vec::new());
    loop {
        let left = deadline
            .checked_duration_since(std::time::Instant::now())
            .filter(|left| !left.is_zero())
            .ok_or_else(|| refused("timeout"))?;
        stream.set_read_timeout(Some(left))?;
        let mut byte = [0];
        stream.read_exact(&mut byte).map_err(|_| refused("read"))?;
        if byte[0] == b'\n' {
            break;
        }
        if bytes.len() >= 4096 {
            return Err(refused("size"));
        }
        bytes.push(byte[0]);
    }
    let bootstrap: Bootstrap =
        serde_json::from_slice(&bytes).map_err(|error| refused(&json_step(&error)))?;
    let encoded = Zeroizing::new(bootstrap.private_key);
    if bootstrap.version != 2 {
        return Err(refused("version"));
    }
    if !bootstrap.install.starts_with("inst_")
        || bootstrap.install.len() <= 5
        || !cmux_link::stamp::valid_id(&bootstrap.install)
    {
        return Err(refused("install"));
    }
    if !bootstrap.team.strip_prefix("team_").is_some_and(|hex| {
        hex.len() == 20 && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    }) {
        return Err(refused("team"));
    }
    if !native_id(&bootstrap.mesh, "mesh_") {
        return Err(refused("mesh"));
    }
    let decoded =
        Zeroizing::new(STANDARD.decode(encoded.as_bytes()).map_err(|_| refused("private_key"))?);
    if decoded.len() != 32 {
        return Err(refused("private_key"));
    }
    let mut key = Zeroizing::new([0u8; 32]);
    key.copy_from_slice(&decoded);
    let route = super::native_route::NativeRoute::new(
        bootstrap.tenant,
        bootstrap.mesh,
        &bootstrap.device,
        bootstrap.ipv4_cidr,
        bootstrap.tunnel,
    )
    .map_err(|error| {
        let message = error.to_string();
        let step = message.strip_prefix("cloud.native.route_refused: ").unwrap_or(&message);
        refused(&format!("route {step}"))
    })?;
    Ok(Identity {
        config: LinkConfig { install: bootstrap.install, port: 0, server_identity: None },
        key,
        route,
    })
}

/// Names a missing or unknown field (a schema mismatch between app and CLI), never a value: serde's
/// other messages can quote what was sent.
fn json_step(error: &serde_json::Error) -> String {
    let message = error.to_string();
    for kind in ["missing field `", "unknown field `"] {
        if let Some(field) = message.strip_prefix(kind).and_then(|rest| rest.split('`').next())
            && field.len() <= 64
            && field.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
        {
            return format!("json {}{field}", kind.trim_end_matches('`'));
        }
    }
    format!("json {:?}", error.classify()).to_lowercase()
}

pub(super) fn native_id(value: &str, prefix: &str) -> bool {
    value.strip_prefix(prefix).is_some_and(|id| {
        id.len() == 26 && id.bytes().all(|b| b"0123456789abcdefghjkmnpqrstvwxyz".contains(&b))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;

    fn bootstrap() -> serde_json::Value {
        serde_json::json!({"version": 2, "install": "inst_native",
            "team": format!("team_{}", "a".repeat(20)), "mesh": format!("mesh_{}", "0".repeat(26)),
            "tenant": "tenant_a", "ipv4_cidr": "10.128.0.0/20", "device": format!("dev_{}", "0".repeat(26)),
            "tunnel": {"id": format!("tun_{}", "0".repeat(26)), "meshId": format!("mesh_{}", "0".repeat(26)),
                "deviceId": format!("dev_{}", "0".repeat(26)), "endpointHost": "203.0.113.30", "endpointPort": 51820,
                "serverPublicKey": STANDARD.encode([3u8; 32]), "interfaceAddress": "100.64.0.1/32", "meshAddress": "10.128.0.10",
                "allowedIps": ["10.128.0.0/20"], "mtu": 1280, "persistentKeepaliveSeconds": 25},
            "private_key": STANDARD.encode([7u8; 32])})
    }

    #[test]
    fn native_cloud_broker_rejects_malformed_scope_or_key_without_echoing_it() {
        for (field, value) in [
            ("version", serde_json::json!(3)),
            ("install", serde_json::json!("host_other")),
            ("team", serde_json::json!("team_other")),
            ("mesh", serde_json::json!("mesh_other")),
            ("private_key", serde_json::json!("private-invalid-key")),
            ("origin", serde_json::json!("attacker-choice")),
        ] {
            let (mut reader, mut parent) = UnixStream::pair().unwrap();
            let mut value_to_send = bootstrap();
            value_to_send[field] = value;
            writeln!(parent, "{value_to_send}").unwrap();
            let error = match read_identity(&mut reader) {
                Err(error) => error,
                Ok(_) => panic!("must refuse"),
            };
            let message = error.to_string();
            assert!(message.starts_with("cloud.native.bootstrap_refused: "), "{message}");
            assert!(
                !message.contains("attacker-choice") && !message.contains("private-invalid-key"),
                "{message}"
            );
        }
    }

    #[test]
    fn native_cloud_broker_names_a_route_refusal_once() {
        let (mut reader, mut parent) = UnixStream::pair().unwrap();
        let mut value_to_send = bootstrap();
        value_to_send["tunnel"]["meshAddress"] = serde_json::json!("10.129.0.5");
        writeln!(parent, "{value_to_send}").unwrap();
        let Err(error) = read_identity(&mut reader) else { panic!("must refuse") };
        assert_eq!(
            error.to_string(),
            "cloud.native.bootstrap_refused: route meshAddress outside ipv4_cidr"
        );
    }

    #[test]
    fn json_step_names_the_missing_or_unknown_field() {
        #[derive(Debug, serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Probe {
            #[allow(dead_code)]
            version: u32,
        }
        let missing = serde_json::from_str::<Probe>("{}").unwrap_err();
        assert_eq!(json_step(&missing), "json missing field version");
        let unknown = serde_json::from_str::<Probe>(r#"{"version":1,"origin":2}"#).unwrap_err();
        assert_eq!(json_step(&unknown), "json unknown field origin");
    }

    #[test]
    fn native_cloud_broker_rejects_oversized_bootstrap_without_reading_following_frames() {
        let (mut reader, mut parent) = UnixStream::pair().unwrap();
        parent.write_all(&vec![b'x'; 4097]).unwrap();
        assert!(read_identity(&mut reader).is_err());
    }
}
