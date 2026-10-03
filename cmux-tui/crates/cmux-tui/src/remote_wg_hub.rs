//! `cmux-tui wg hub`: one WireGuard tunnel shared by every sidecar on the
//! machine, plus the control socket for path events and datagram ports
//! (transport.md 12a).

use super::*;

struct WgHubFlags {
    config: PathBuf,
    socket: PathBuf,
    control: Option<PathBuf>,
    exit_with_parent: bool,
}

fn parse_wg_hub_flags(args: &[String]) -> anyhow::Result<WgHubFlags> {
    let mut config = None;
    let mut socket = None;
    let mut control = None;
    let mut exit_with_parent = false;
    let mut index = 0;
    while index < args.len() {
        let argument = args[index].as_str();
        index += 1;
        let mut value = |name: &str| -> anyhow::Result<PathBuf> {
            let value = args
                .get(index)
                .cloned()
                .ok_or_else(|| anyhow!(catalog().remote_client.option_needs_value(name)))?;
            index += 1;
            Ok(PathBuf::from(value))
        };
        match argument {
            "--config" => {
                if config.replace(value("--config")?).is_some() {
                    return Err(anyhow!(catalog().remote_client.option_once("--config")));
                }
            }
            "--socket" => {
                if socket.replace(value("--socket")?).is_some() {
                    return Err(anyhow!(catalog().remote_client.option_once("--socket")));
                }
            }
            "--control" => {
                if control.replace(value("--control")?).is_some() {
                    return Err(anyhow!(catalog().remote_client.option_once("--control")));
                }
            }
            "--exit-with-parent" => exit_with_parent = true,
            "-h" | "--help" => return Err(anyhow!(catalog().remote_client.help_invalid_options)),
            other => return Err(anyhow!(catalog().remote_client.unknown_option(other))),
        }
    }
    Ok(WgHubFlags {
        config: config
            .ok_or_else(|| anyhow!(catalog().remote_client.wg_hub_option_required("--config")))?,
        socket: socket
            .ok_or_else(|| anyhow!(catalog().remote_client.wg_hub_option_required("--socket")))?,
        control,
        exit_with_parent,
    })
}

/// `cmux-tui wg hub --config <wg-quick> --socket <unix path> [--control
/// <unix path>]`: own one WireGuard tunnel and serve SOCKS5 CONNECT for
/// sidecars on a Unix socket, plus, with `--control`, path events and the
/// datagram service (transport.md 12a).
///
/// Prints one JSON readiness line, then runs until SIGTERM, SIGINT, or the
/// opted-in parent lifecycle ends. It removes the socket on the way out.
/// Every error before readiness exits non-zero through the caller.
pub(super) fn run_wg(args: &[String]) -> anyhow::Result<()> {
    match args.first().map(String::as_str) {
        Some("hub") => {}
        Some(action) => return Err(anyhow!(catalog().remote_client.unknown_action("wg", action))),
        None => return Err(anyhow!(catalog().remote_client.wg_hub_help)),
    }
    let flags = parse_wg_hub_flags(&args[1..])?;
    let owner = flags.exit_with_parent.then(current_parent_process_id);
    let async_runtime = tokio_runtime()?;
    let (net, paths) =
        start_wireguard_hub_tunnel(&async_runtime, &flags.config, WIREGUARD_HUB_START_TIMEOUT)?;
    async_runtime.block_on(net.wait_for_handshake(WIREGUARD_HUB_HANDSHAKE_TIMEOUT)).map_err(
        |error| anyhow!(catalog().remote_client.wireguard_start_failed(&error.to_string())),
    )?;
    let hub = async_runtime
        .block_on(cmux_remote::wireguard_hub::serve_wireguard_hub(Arc::clone(&net), flags.socket))
        .map_err(|error| {
            anyhow!(catalog().remote_client.wireguard_hub_serve_failed(&error.to_string()))
        })?;
    let control = match flags.control {
        Some(path) => Some(
            async_runtime
                .block_on(cmux_remote::wireguard_hub_control::serve_hub_control(
                    net,
                    Some(paths),
                    path,
                ))
                .map_err(|error| {
                    anyhow!(catalog().remote_client.wireguard_hub_serve_failed(&error.to_string()))
                })?,
        ),
        None => None,
    };
    let mut ready = serde_json::json!({
        "event": "hub-ready",
        "socket": hub.path().display().to_string(),
        "routes": hub.routes().iter().map(ToString::to_string).collect::<Vec<_>>(),
    });
    if let Some(control) = &control {
        ready["control"] = serde_json::json!(control.path().display().to_string());
    }
    println!("{}", serde_json::to_string(&ready)?);
    let _ = io::stdout().flush();
    async_runtime
        .block_on(async {
            if let Some(owner) = owner {
                tokio::select! {
                    result = crate::wait_for_shutdown_signal_async() => result,
                    _ = wait_for_parent_exit(owner) => Ok(()),
                }
            } else {
                crate::wait_for_shutdown_signal_async().await
            }
        })
        .map_err(|error| {
            anyhow!(catalog().remote_client.wireguard_hub_signal_failed(&error.to_string()))
        })?;
    if let Some(control) = control {
        async_runtime.block_on(control.shutdown()).map_err(|error| {
            anyhow!(catalog().remote_client.wireguard_hub_serve_failed(&error.to_string()))
        })?;
    }
    async_runtime.block_on(hub.shutdown()).map_err(|error| {
        anyhow!(catalog().remote_client.wireguard_hub_serve_failed(&error.to_string()))
    })?;
    Ok(())
}

/// Starts the hub's tunnel with a deadline around endpoint resolution and UDP
/// setup. A DNS/network stall must produce a child error so the app can retry,
/// rather than leaving the Unix socket absent until the app-side readiness
/// timeout.
///
/// The hub's tunnel: one UDP path under a one-path multipath, so path events
/// come from the selector (transport.md 12a). The hub's peer today is the
/// device's cloud-region tunnel. Probes run only when the config names a
/// probe responder (`PeerAddress =`, a cmux endpoint); a plain WireGuard
/// gateway does not answer them, and unanswered probes would report a
/// working path as lossy.
fn start_wireguard_hub_tunnel(
    runtime: &tokio::runtime::Runtime,
    path: &Path,
    timeout: Duration,
) -> anyhow::Result<(Arc<cmux_wg::WgNet>, cmux_wg::MultipathControl)> {
    let config = read_wireguard_config(path)?;
    let probes = (!config.peer_addresses.is_empty()).then(cmux_wg::ProbeConfig::default);
    let kind = cmux_wg::PathKind::ViaCloudRegion;
    // The timeout future must be built inside the runtime: `tokio::time::timeout`
    // registers its sleep with the current reactor at construction, and there is
    // none on this thread, so building it as `block_on`'s argument panics.
    let (net, paths) = runtime
        .block_on(async move {
            let start = cmux_wg::WgNet::start_single_path(config, kind, probes);
            tokio::time::timeout(timeout, start).await
        })
        .map_err(|_| anyhow!("WireGuard startup timed out after {timeout:?}"))?
        .map_err(|error| {
            anyhow!(catalog().remote_client.wireguard_start_failed(&error.to_string()))
        })?;
    Ok((Arc::new(net), paths))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wg_hub_flags_require_config_and_socket() {
        let full =
            ["hub", "--config", "/tmp/wg.conf", "--socket", "/tmp/wg.sock"].map(str::to_string);
        let flags = parse_wg_hub_flags(&full[1..]).unwrap();
        assert_eq!(flags.config, PathBuf::from("/tmp/wg.conf"));
        assert_eq!(flags.socket, PathBuf::from("/tmp/wg.sock"));
        assert!(!flags.exit_with_parent);
        let owned = ["--config", "/tmp/wg.conf", "--socket", "/tmp/wg.sock", "--exit-with-parent"]
            .map(str::to_string);
        assert!(parse_wg_hub_flags(&owned).unwrap().exit_with_parent);
        let missing = ["--config", "/tmp/wg.conf"].map(str::to_string);
        assert!(parse_wg_hub_flags(&missing).is_err());
        let unknown =
            ["--config", "/tmp/wg.conf", "--socket", "/tmp/s", "--bogus"].map(str::to_string);
        assert!(parse_wg_hub_flags(&unknown).is_err());
        let not_hub = ["frobnicate"].map(str::to_string);
        assert!(run_wg(&not_hub).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn wireguard_hub_start_deadline_is_built_inside_the_runtime() {
        use std::os::unix::fs::PermissionsExt;

        // `wg hub` runs on a plain thread and hands its runtime to the starter.
        // The deadline future used to be built as `block_on`'s argument, where no
        // reactor exists, and every hub start panicked with "there is no reactor
        // running". A literal endpoint keeps DNS out of the test; the start may
        // still fail, and any `Result` is the pass condition.
        let directory = tempfile::tempdir().unwrap();
        let config = directory.path().join("hub.conf");
        fs::write(
            &config,
            "[Interface]\nPrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\nAddress = 100.64.0.1/32\nMTU = 1200\n\n[Peer]\nPublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\nAllowedIPs = 10.0.0.0/24\nEndpoint = 127.0.0.1:1\n",
        )
        .unwrap();
        fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
        let runtime = tokio_runtime().unwrap();
        let started = start_wireguard_hub_tunnel(&runtime, &config, Duration::from_secs(5));
        drop(started);
    }
}
