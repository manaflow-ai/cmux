//! `remote-probe` and `remote update-need`: what this build advertises, and how
//! it orders against another build's probe.

use std::collections::BTreeSet;
use std::io::{self, Read as _};

use anyhow::{Context as _, anyhow};
use cmux_build_identity::BUILD_IDENTITY;
use cmux_remote::ssh_bootstrap::{DISTRIBUTION_VERSION, NPM_BOOTSTRAP_VERSION};
use cmux_remote_protocol::REMOTE_PROTOCOL_VERSION;
use serde_json::Value;

use crate::localization::catalog;

/// Advertised by `remote-probe --json` so a control plane can choose routes the client can use.
///
/// `direct-ws-user-agent`: direct WebSocket dials carry a User-Agent, which
/// hosted ingress on branded machine domains requires.
/// `wireguard-hub`: `remote connect --wireguard-hub` and `wg hub` exist, so the
/// app may reach private-network machines through a shared in-process tunnel.
/// `wireguard-hub-token`: `wg hub --client-token-stdin` and `--config -`, and
/// `remote connect --wireguard-hub-token-stdin`, so only the app's own clients
/// use the hub and its config needs no file.
/// `remote-link-mux-socket` and `remote-link-strict-flags`: see
/// `cmux_remote::provider::REMOTE_LINK_MUX_SOCKET_CAPABILITY`; an SSH client
/// that needs one refuses a remote without it (cx-z3zh).
/// `cloud-browser-network`: Cloud browser proxy routes preserve the guest
/// machine's network and loopback context.
/// `ssh-payload-download` and `ssh-payload-macos-from-client`: see
/// `cmux_remote::SSH_PAYLOAD_DOWNLOAD_CAPABILITY` and
/// `cmux_remote::SSH_PAYLOAD_MACOS_FROM_CLIENT_CAPABILITY`.
pub const PROBE_CAPABILITIES: &[&str] = &[
    "direct-ws-user-agent",
    "wireguard-hub",
    "wireguard-hub-token",
    "browser-proxy",
    "cloud-browser-network",
    cmux_remote::provider::REMOTE_LINK_MUX_SOCKET_CAPABILITY,
    cmux_remote::provider::REMOTE_LINK_STRICT_FLAGS_CAPABILITY,
    cmux_remote::SSH_PAYLOAD_DOWNLOAD_CAPABILITY,
    cmux_remote::SSH_PAYLOAD_MACOS_FROM_CLIENT_CAPABILITY,
];

/// `remote update-need --probe-json <file|->` (cx-3r9mt): whether the machine
/// whose `remote-probe --json` this is runs an older, the same or a newer
/// cmux-tui than this binary, by `cmux_remote::update_need`. Exit 0 for every
/// answer; only bad input fails.
pub(super) fn run_update_need(args: &[String]) -> anyhow::Result<()> {
    use cmux_remote::update_need::{BuildFacts, update_need};
    let source = match args {
        [flag, source] if flag == "--probe-json" => Some(source.as_str()),
        [single] => single.strip_prefix("--probe-json="),
        _ => None,
    };
    let source = source.ok_or_else(|| anyhow!(catalog().remote.remote_update_need_help))?;
    let text = if source == "-" {
        let mut text = String::new();
        io::stdin().read_to_string(&mut text).context("read the probe JSON from stdin")?;
        text
    } else {
        cmux_blocking::fs::read_to_string(source).with_context(|| format!("read {source}"))?
    };
    let probe: Value = serde_json::from_str(&text).context("the probe is not JSON")?;
    let object = probe.as_object().ok_or_else(|| anyhow!("the probe is not a JSON object"))?;
    let remote = BuildFacts {
        commit: object.get("build_identity").and_then(Value::as_str).map(str::to_owned),
        time: object.get("build_time").and_then(Value::as_u64).unwrap_or(0),
        capabilities: object
            .get("daemon_capabilities")
            .and_then(Value::as_array)
            .map(|list| list.iter().filter_map(Value::as_str).map(str::to_owned).collect()),
    };
    let local = BuildFacts {
        commit: Some(BUILD_IDENTITY.to_owned()),
        time: cmux_build_identity::BUILD_TIME,
        capabilities: Some(
            cmux_tui_core::server::build_capabilities().into_iter().map(str::to_owned).collect(),
        ),
    };
    let (need, reason) = update_need(&local, &remote);
    let side = |facts: &BuildFacts| {
        serde_json::json!({
            "commit": facts.commit,
            "time": facts.time,
            "capabilities_count": facts.capabilities.as_ref().map(BTreeSet::len),
        })
    };
    let mut answer = serde_json::Map::new();
    answer.insert("need".into(), serde_json::json!(need));
    answer.insert("reason".into(), serde_json::json!(reason));
    answer.insert("remote".into(), side(&remote));
    answer.insert("local".into(), side(&local));
    if reason == cmux_remote::update_need::Reason::Incomparable {
        answer.insert(
            "warning".into(),
            "each build serves a capability the other lacks; neither replaces the other".into(),
        );
    }
    println!("{}", Value::Object(answer));
    Ok(())
}

/// `remote-probe --json`. Fields stay in key order, the order the output has always had.
#[derive(serde::Serialize)]
struct RemoteProbe {
    app: &'static str,
    arch: &'static str,
    build_identity: &'static str,
    /// cx-3r9mt: what `remote update-need` orders builds by.
    build_time: u64,
    /// Client-side transport capabilities a control plane can key routing on.
    capabilities: &'static [&'static str],
    /// Only on request: the SSH bootstrap of every client reads at most 4096
    /// bytes of this output, and the list alone is larger (cx-3r9mt).
    #[serde(skip_serializing_if = "Option::is_none")]
    daemon_capabilities: Option<Vec<&'static str>>,
    distribution_version: &'static str,
    npm_bootstrap_version: Option<&'static str>,
    os: &'static str,
    remote_protocol: u8,
    version: &'static str,
}

impl RemoteProbe {
    fn current(build_facts: bool) -> Self {
        Self {
            app: "cmux-tui",
            arch: std::env::consts::ARCH,
            build_identity: BUILD_IDENTITY,
            build_time: cmux_build_identity::BUILD_TIME,
            capabilities: PROBE_CAPABILITIES,
            daemon_capabilities: build_facts.then(cmux_tui_core::server::build_capabilities),
            distribution_version: DISTRIBUTION_VERSION,
            npm_bootstrap_version: NPM_BOOTSTRAP_VERSION,
            os: std::env::consts::OS,
            remote_protocol: REMOTE_PROTOCOL_VERSION,
            version: env!("CARGO_PKG_VERSION"),
        }
    }
}

pub(super) fn run_probe(args: &[String]) -> anyhow::Result<()> {
    let value = RemoteProbe::current(args.iter().any(|argument| argument == "--build-facts"));
    if args.iter().any(|argument| argument == "--json") {
        println!("{}", serde_json::to_string(&value)?);
    } else {
        println!(
            "cmux-tui {} remote-protocol={} {}-{}",
            env!("CARGO_PKG_VERSION"),
            REMOTE_PROTOCOL_VERSION,
            std::env::consts::OS,
            std::env::consts::ARCH
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_capabilities_include_direct_ws_user_agent() {
        assert!(PROBE_CAPABILITIES.contains(&"direct-ws-user-agent"));
        assert!(PROBE_CAPABILITIES.contains(&"wireguard-hub"));
        assert!(PROBE_CAPABILITIES.contains(&"wireguard-hub-token"));
    }

    #[test]
    fn probe_json_keeps_its_key_order_and_daemon_capabilities_on_request() {
        let text = serde_json::to_string(&RemoteProbe::current(false)).unwrap();
        let value: Value = serde_json::from_str(&text).unwrap();
        // serde_json's map sorts keys: the bytes `serde_json::json!` wrote before.
        assert_eq!(text, serde_json::to_string(&value).unwrap());
        assert_eq!(value.get("app").and_then(Value::as_str), Some("cmux-tui"));
        assert!(value.get("daemon_capabilities").is_none());
        let with_facts = serde_json::to_value(RemoteProbe::current(true)).unwrap();
        let list = with_facts.get("daemon_capabilities").and_then(Value::as_array);
        assert!(list.is_some_and(|list| !list.is_empty()));
    }
}
