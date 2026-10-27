//! `cmux-tui wg hub`: one WireGuard tunnel shared by every sidecar on the
//! machine, plus the control socket for path events and datagram ports
//! (transport.md 12a).

use super::*;

struct WgHubFlags {
    config: PathBuf,
    socket: PathBuf,
    control: Option<PathBuf>,
    probes: bool,
    send_buffer: Option<usize>,
    exit_with_parent: bool,
}

fn parse_wg_hub_flags(args: &[String]) -> anyhow::Result<WgHubFlags> {
    let mut config = None;
    let mut socket = None;
    let mut control = None;
    let mut probes = false;
    let mut send_buffer = None;
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
            "--probes" => probes = true,
            "--send-buffer" => {
                let raw = value("--send-buffer")?;
                let bytes = raw.to_str().and_then(|text| text.parse::<usize>().ok());
                let Some(bytes) = bytes.filter(|bytes| SEND_BUFFER_RANGE.contains(bytes)) else {
                    let message =
                        catalog().remote_client.invalid_option_value("--send-buffer", "BYTES");
                    return Err(anyhow!(message));
                };
                if send_buffer.replace(bytes).is_some() {
                    return Err(anyhow!(catalog().remote_client.option_once("--send-buffer")));
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
        probes,
        send_buffer,
        exit_with_parent,
    })
}

/// `cmux-tui wg hub --config <wg-quick> --socket <unix path> [--control
/// <unix path>] [--probes] [--send-buffer <bytes>]`: own one WireGuard tunnel and serve SOCKS5 CONNECT for
/// sidecars on a Unix socket, plus, with `--control`, path events and the
/// datagram service (transport.md 12a).
///
/// Prints one JSON readiness line, then runs until SIGTERM, SIGINT, or the
/// opted-in parent lifecycle ends. It removes the socket on the way out.
/// Every error before readiness exits non-zero through the caller.
pub(super) fn run_wg(args: &[String]) -> anyhow::Result<()> {
    match args.first().map(String::as_str) {
        Some("hub") => {}
        Some("dial") => return run_wg_dial(&args[1..]),
        Some(action) => return Err(anyhow!(catalog().remote_client.unknown_action("wg", action))),
        None => return Err(anyhow!(catalog().remote_client.wg_hub_help)),
    }
    let flags = parse_wg_hub_flags(&args[1..])?;
    let owner = flags.exit_with_parent.then(current_parent_process_id);
    let async_runtime = tokio_runtime()?;
    let (net, paths) = start_wireguard_hub_tunnel(
        &async_runtime,
        &flags.config,
        HubTunnel {
            probes: flags.probes,
            send_buffer: Some(flags.send_buffer.unwrap_or(cmux_wg::MIN_SEND_BUFFER)),
        },
        WIREGUARD_HUB_START_TIMEOUT,
    )?;
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
    // Stop both even when the first fails; report the first failure.
    let control = control.map(|control| async_runtime.block_on(control.shutdown()));
    let hub = async_runtime.block_on(hub.shutdown());
    for result in [control.unwrap_or(Ok(())), hub] {
        result.map_err(|error| {
            anyhow!(catalog().remote_client.wireguard_hub_serve_failed(&error.to_string()))
        })?;
    }
    Ok(())
}

/// `cmux wg dial --hub PATH HOST PORT`: one TCP stream to HOST:PORT through a running hub,
/// on stdin and stdout, for an ssh `ProxyCommand` (`ssh -o ProxyCommand='cmux wg dial --hub
/// PATH %h %p' cmux@10.0.0.7`; `cmux cloud enroll-machine` writes such a Host block). HOST is
/// an address inside the hub's AllowedIPs, as the hub dials nothing else. Exits when either
/// side ends.
fn run_wg_dial(args: &[String]) -> anyhow::Result<()> {
    let [flag, hub, host, port] = args else { return Err(anyhow!(WG_DIAL_USAGE)) };
    let port = port.parse::<u16>().ok().filter(|port| *port > 0);
    let (true, Some(port)) = (flag == "--hub", port) else { return Err(anyhow!(WG_DIAL_USAGE)) };
    let runtime = tokio_runtime()?;
    // SIGINT, SIGTERM or SIGHUP (ssh going away) ends the bridge even on a quiet connection.
    let result = runtime.block_on(async {
        tokio::select! {
            result = bridge_through_hub(
                Path::new(hub),
                host,
                port,
                tokio::io::stdin(),
                tokio::io::stdout(),
            ) => result,
            result = crate::wait_for_shutdown_signal_async() => {
                result.map_err(|error| anyhow!("{error}"))
            }
        }
    });
    // Tokio reads stdin on a thread that cannot be cancelled: do not wait for its next byte.
    runtime.shutdown_background();
    result
}

const WG_DIAL_USAGE: &str = "USAGE: cmux wg dial --hub PATH HOST PORT";

async fn bridge_through_hub<R, W>(
    hub: &Path,
    host: &str,
    port: u16,
    mut input: R,
    mut output: W,
) -> anyhow::Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin,
{
    use tokio::io::{AsyncWriteExt, copy, split};
    let stream =
        SocksDialer::new(hub).dial(host, port).await.map_err(|error| anyhow!("{error}"))?;
    let (mut from_peer, mut to_peer) = split(stream);
    // The end of the input half-closes the stream and the peer's answer still drains: the
    // bridge ends when the peer closes (or output fails, e.g. ssh stopped reading), or on an
    // upload error.
    let upload = async {
        copy(&mut input, &mut to_peer).await?;
        to_peer.shutdown().await?;
        std::future::pending::<io::Result<()>>().await
    };
    let download = async {
        copy(&mut from_peer, &mut output).await?;
        output.shutdown().await
    };
    tokio::select! {
        result = upload => result?,
        result = download => result?,
    }
    Ok(())
}

/// The `--send-buffer` values the hub accepts. Below the minimum, macOS
/// would refuse full-size datagrams. Above the maximum, macOS refuses the
/// option, and a bigger buffer only moves the queue back into the kernel.
/// Linux silently limits the value to `net.core.wmem_max` (about 208 KiB by
/// default), so there the effective upper bound is usually lower.
const SEND_BUFFER_RANGE: std::ops::RangeInclusive<usize> =
    cmux_wg::MIN_SEND_BUFFER..=4 * 1024 * 1024;

/// How the hub's tunnel is started.
#[derive(Clone, Copy, Default)]
struct HubTunnel {
    probes: bool,
    send_buffer: Option<usize>,
}

/// Starts the hub's tunnel with a deadline around endpoint resolution and UDP
/// setup. A DNS/network stall must produce a child error so the app can retry,
/// rather than leaving the Unix socket absent until the app-side readiness
/// timeout.
///
/// The hub's tunnel: one UDP path under a one-path multipath, so path events
/// come from the selector (transport.md 12a). The hub's peer today is the
/// device's cloud-region tunnel. Probes run only with `--probes`: they need
/// a peer that answers them (a cmux endpoint at the config's `PeerAddress`,
/// or the base of its first allowed network); a plain WireGuard gateway does
/// not, and unanswered probes would report a working path as lossy.
///
/// `send_buffer` shrinks the UDP socket's send buffer so a backlog forms in
/// the engine's priority queues instead of the kernel. The hub uses the
/// smallest buffer unless `--send-buffer` asks for more: under a 20 Mbit/s
/// bottleneck it cut media's wait during a bulk upload from about 33 ms to
/// about 8 ms (p50) without changing upload throughput (fs round 6).
fn start_wireguard_hub_tunnel(
    runtime: &tokio::runtime::Runtime,
    path: &Path,
    options: HubTunnel,
    timeout: Duration,
) -> anyhow::Result<(Arc<cmux_wg::WgNet>, cmux_wg::MultipathControl)> {
    let config = read_wireguard_config(path)?;
    let probes = options.probes.then(cmux_wg::ProbeConfig::default);
    let send_buffer = options.send_buffer;
    let kind = cmux_wg::PathKind::ViaCloudRegion;
    // The timeout future must be built inside the runtime: `tokio::time::timeout`
    // registers its sleep with the current reactor at construction, and there is
    // none on this thread, so building it as `block_on`'s argument panics.
    let (net, paths) = runtime
        .block_on(async move {
            let start = cmux_wg::WgNet::start_single_path(config, kind, probes, send_buffer);
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
        assert!(!flags.probes && flags.control.is_none());
        let measured =
            ["--config", "c", "--socket", "s", "--control", "k", "--probes"].map(str::to_string);
        let measured = parse_wg_hub_flags(&measured).unwrap();
        assert!(measured.probes);
        let sized =
            ["--config", "c", "--socket", "s", "--send-buffer", "32768"].map(str::to_string);
        assert_eq!(parse_wg_hub_flags(&sized).unwrap().send_buffer, Some(32 * 1024));
        let bad = ["--config", "c", "--socket", "s", "--send-buffer", "lots"].map(str::to_string);
        assert!(parse_wg_hub_flags(&bad).is_err());
        let huge =
            ["--config", "c", "--socket", "s", "--send-buffer", "8388608"].map(str::to_string);
        assert!(parse_wg_hub_flags(&huge).is_err(), "above 4 MiB is refused");
        let tiny = ["--config", "c", "--socket", "s", "--send-buffer", "1"].map(str::to_string);
        assert!(parse_wg_hub_flags(&tiny).is_err(), "below 16 KiB is refused");
        let floor =
            ["--config", "c", "--socket", "s", "--send-buffer", "16384"].map(str::to_string);
        assert_eq!(parse_wg_hub_flags(&floor).unwrap().send_buffer, Some(16 * 1024));
        assert_eq!(measured.control, Some(PathBuf::from("k")));
        let missing = ["--config", "/tmp/wg.conf"].map(str::to_string);
        assert!(parse_wg_hub_flags(&missing).is_err());
        let unknown =
            ["--config", "/tmp/wg.conf", "--socket", "/tmp/s", "--bogus"].map(str::to_string);
        assert!(parse_wg_hub_flags(&unknown).is_err());
        let not_hub = ["frobnicate"].map(str::to_string);
        assert!(run_wg(&not_hub).is_err());
    }

    #[test]
    fn wg_dial_takes_a_hub_a_host_and_a_port() {
        for bad in [
            &["dial"][..],
            &["dial", "--hub", "/tmp/h.sock", "10.0.0.7"],
            &["dial", "--hub", "/tmp/h.sock", "10.0.0.7", "0"],
            &["dial", "--hub", "/tmp/h.sock", "10.0.0.7", "ssh"],
            &["dial", "--socket", "/tmp/h.sock", "10.0.0.7", "22"],
        ] {
            let args = bad.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
            assert_eq!(run_wg(&args).unwrap_err().to_string(), WG_DIAL_USAGE, "{bad:?}");
        }
    }

    /// The bridge speaks SOCKS5 CONNECT to the hub, then carries bytes both ways: a fake
    /// hub that echoes gets back what the bridge read from its input.
    #[cfg(unix)]
    #[tokio::test]
    async fn wg_dial_bridges_stdio_through_the_hub() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let directory = tempfile::tempdir().unwrap();
        let hub = directory.path().join("hub.sock");
        let listener = tokio::net::UnixListener::bind(&hub).unwrap();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut greeting = [0u8; 2];
            stream.read_exact(&mut greeting).await.unwrap();
            let mut methods = vec![0u8; usize::from(greeting[1])];
            stream.read_exact(&mut methods).await.unwrap();
            stream.write_all(&[5, 0]).await.unwrap();
            let mut request = [0u8; 10];
            stream.read_exact(&mut request).await.unwrap();
            assert_eq!(&request[..4], &[5, 1, 0, 1], "CONNECT to an IPv4 literal");
            assert_eq!(&request[4..], &[10, 0, 0, 7, 0, 22]);
            stream.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await.unwrap();
            // Read to the client's half-close, then answer: the bridge must still be listening.
            let mut line = Vec::new();
            stream.read_to_end(&mut line).await.unwrap();
            stream.write_all(&line).await.unwrap();
        });
        let mut output = Vec::new();
        bridge_through_hub(&hub, "10.0.0.7", 22, &b"hello"[..], &mut output).await.unwrap();
        server.await.unwrap();
        assert_eq!(output, b"hello");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn wg_dial_says_when_no_hub_runs() {
        let directory = tempfile::tempdir().unwrap();
        let error = bridge_through_hub(
            &directory.path().join("none.sock"),
            "10.0.0.7",
            22,
            &b""[..],
            Vec::new(),
        )
        .await
        .unwrap_err();
        assert!(error.to_string().contains("is not reachable"), "{error}");
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
        let started = start_wireguard_hub_tunnel(
            &runtime,
            &config,
            HubTunnel::default(),
            Duration::from_secs(5),
        );
        drop(started);
    }
}
