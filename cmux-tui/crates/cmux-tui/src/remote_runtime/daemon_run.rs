//! The daemon side of the remote runtime: `run_daemon` (state-directory fences, authorization
//! handoff, the listeners and the relay registrations, then the ordered shutdown) and the helpers
//! only it uses.

use super::*;

#[allow(clippy::too_many_arguments)]
pub(super) async fn run_daemon(
    mux_socket: PathBuf,
    options: DaemonRuntimeOptions,
    state_dir: PathBuf,
    link_socket: PathBuf,
    admin_socket: PathBuf,
    shutdown: watch::Receiver<bool>,
    owner_shutdown: watch::Sender<bool>,
    ready: mpsc::SyncSender<Result<DaemonRuntimeInfo, String>>,
) -> anyhow::Result<()> {
    let setup = async {
        let mut startup_shutdown = shutdown.clone();
        let auth_state_dir = state_dir.join("auth");
        let mut lifecycle_fenced = read_daemon_lifecycle_fence(&state_dir)
            .context(catalog().remote.verify_lifecycle_fence)?;
        if lifecycle_fenced {
            persist_daemon_lifecycle_fence(&state_dir)
                .context(catalog().remote.confirm_lifecycle_fence_durability)?;
        }
        let auth_state_preexisting =
            auth_state_dir.try_exists().context(catalog().remote.inspect_authorization_state)?;
        let auth_state_schema = auth_state_preexisting
            .then(|| persisted_auth_state_schema(&auth_state_dir))
            .transpose()
            .context(catalog().remote.inspect_authorization_schema)?;
        if matches!(auth_state_schema, Some(PersistedAuthStateSchema::Legacy))
            || matches!(auth_state_schema, Some(PersistedAuthStateSchema::Missing))
            || (lifecycle_fenced && !auth_state_preexisting)
        {
            return Err(anyhow!(catalog().remote.legacy_authorization_requires_migration));
        }
        let auth = load_daemon_auth_during_handoff(
            &auth_state_dir,
            &options.session,
            &mut startup_shutdown,
            DAEMON_AUTH_LEASE_RETRY_TIMEOUT,
        )
        .await?;
        // Version 2 authorization state is the rollback fence understood by
        // older binaries. Publish the lifecycle marker only after that state
        // is durable and while its exclusive lease is still held.
        if !auth_state_preexisting && !lifecycle_fenced {
            ensure_secure_directory(&state_dir, DirectoryAccess::OwnerControlled)
                .context(catalog().remote.prepare_lifecycle_state)?;
            #[cfg(test)]
            pause_daemon_cleanup(&state_dir, DaemonCleanupPausePhase::BeforeLifecycleFence);
            persist_daemon_lifecycle_fence(&state_dir)?;
            lifecycle_fenced = true;
        }
        #[cfg(unix)]
        if lifecycle_fenced {
            recover_inactive_predecessor_state(&state_dir, &link_socket, &admin_socket).await?;
        }
        verify_previous_shutdown_outcome(&state_dir, lifecycle_fenced)?;
        if !lifecycle_fenced {
            persist_daemon_lifecycle_fence(&state_dir)?;
        }
        if *startup_shutdown.borrow() {
            return Err(anyhow!("remote daemon startup was cancelled"));
        }
        if let Some(path) = &options.carrier_grant_config {
            install_grant_verifier(&auth, path);
        }
        let (daemon, clients) = cmux_remote::daemon::RemoteDaemon::with_policy(
            auth.clone(),
            SessionLimits::default(),
            DaemonSessionPolicy { resume_lease: options.resume_lease },
        )?;
        #[cfg(unix)]
        let workspace = crate::machine_secrets::daemon_workspace_service(
            &auth,
            &state_dir,
            options.carrier_grant_config.as_deref(),
        );
        #[cfg(not(unix))]
        let workspace = cmux_remote::workspace::WorkspaceService::new();
        // The admin proof and service forwarding must use the same resolved
        // destination, including when the configured path is a symlink.
        let mux_binding = MuxBinding::new(&mux_socket, &link_socket)?;
        let mux_socket = mux_binding.mux_socket.clone();

        let lifecycle_id = uuid::Uuid::new_v4().to_string();
        let preliminary_runtime = persist_runtime_info(
            &state_dir,
            &DaemonRuntimeInfo {
                session: options.session.clone(),
                state_dir: state_dir.clone(),
                link_socket: link_socket.clone(),
                admin_socket: admin_socket.clone(),
                daemon_fingerprint: auth.identity().fingerprint(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some(lifecycle_id.clone()),
                replaceable_sidecar: options.replaceable_sidecar,
            },
        );
        if let Err(error) = preliminary_runtime {
            if error.downcast_ref::<CommittedRuntimeInfoError>().is_some() {
                return finalize_daemon_authorization(auth, state_dir, lifecycle_id, vec![error])
                    .await;
            }
            return Err(error);
        }
        let transport_setup: anyhow::Result<_> = async {
            #[cfg(test)]
            pause_daemon_cleanup(&state_dir, DaemonCleanupPausePhase::BeforeListenerStartup);
            let unix = serve_unix_with_shutdown(
                daemon.clone(),
                &link_socket,
                MAX_CARRIER_FRAME_BYTES,
                Some(owner_shutdown.clone()),
            )
            .await?;
            let websocket = match options.direct_websocket {
                Some(address) => Some(
                    serve_direct_websocket_with_options(
                        daemon.clone(),
                        address,
                        MAX_CARRIER_FRAME_BYTES,
                        DirectWebSocketOptions {
                            // `--remote-ws-trusted-carrier` is the operator's explicit
                            // opt-in for compatibility machines; the daemon still grants
                            // carrier auth only to private-address peers.
                            allow_trusted_carrier_non_loopback: options.trusted_carrier_websocket,
                            ..DirectWebSocketOptions::new(
                                options.allow_insecure_non_loopback,
                                options.trusted_carrier_websocket,
                            )
                        },
                    )
                    .await?,
                ),
                None => None,
            };
            let workspace_http = match options.workspace_http {
                Some(address) => {
                    let server = serve_workspace_http(
                        workspace.clone(),
                        address,
                        state_dir.join("workspace-http.token"),
                    )
                    .await?;
                    crate::client_log::stderr_log!(
                        "remote",
                        "{BIN}: authenticated workspace HTTP at http://{}; bearer token file {}",
                        server.local_addr(),
                        server.token_file().display()
                    );
                    Some(server)
                }
                None => None,
            };

            // The relay registers in the background: a ticket command that
            // fails or hangs, or a relay that is down, is retried and logged
            // while the local sockets serve. Only an invalid relay
            // configuration fails startup.
            let mut relays = Vec::with_capacity(options.relays.len());
            for relay in options.relays.iter().cloned() {
                relays.push(spawn_relay_daemon_registration(
                    daemon.clone(),
                    RelayDaemonConfig {
                        endpoint: relay.endpoint,
                        slot: relay.slot,
                        ticket: String::new(),
                        maximum_frame_bytes: MAX_CARRIER_FRAME_BYTES,
                        control_timeout: Duration::from_secs(15),
                    },
                    relay.credentials,
                    &crate::cli::BIN.to_string(),
                )?);
            }

            #[cfg(not(feature = "iroh-transport"))]
            if options.iroh {
                return Err(anyhow!("Iroh transport is not included in this cmux-tui build"));
            }
            #[cfg(feature = "iroh-transport")]
            let iroh = match options.iroh {
                true => {
                    let config = IrohProviderConfig {
                        secret_key: Some(load_or_create_iroh_secret(&state_dir.join("iroh.key"))?),
                        ..IrohProviderConfig::default()
                    };
                    Some(tokio::select! {
                        result = IrohListener::bind(daemon.clone(), config) => result?,
                        _ = wait_for_shutdown(&mut startup_shutdown) => {
                            return Err(anyhow!("remote daemon startup was cancelled"));
                        }
                    })
                }
                false => None,
            };
            #[cfg(not(feature = "iroh-transport"))]
            let iroh = None::<()>;

            let mut routes = Vec::new();
            for route in &options.advertised_routes {
                push_unique_route(&mut routes, route.clone());
            }
            for relay in &options.relays {
                push_unique_route(&mut routes, relay.endpoint.to_string());
            }
            let mut unix_route = Url::parse("unix:///")?;
            unix_route.set_path(
                link_socket
                    .to_str()
                    .ok_or_else(|| anyhow!("remote link socket path is not valid UTF-8"))?,
            );
            let unix_route = unix_route.to_string();
            let websocket_route = if let Some(server) = &websocket {
                let address = server.local_addr();
                if !address.ip().is_unspecified() {
                    Some(format!("ws://{address}/v1/link"))
                } else {
                    None
                }
            } else {
                None
            };
            #[cfg(feature = "iroh-transport")]
            let iroh_node_id = if let Some(listener) = &iroh {
                let route = listener.route().await?;
                let hints = route.routing_hints();
                let mut route_url = Url::parse(&format!("iroh://{}", route.node_id()))?;
                {
                    let mut query = route_url.query_pairs_mut();
                    if let Some(relay) = hints.get(cmux_remote::provider::ROUTING_RELAY_URL) {
                        query.append_pair("relay_url", relay);
                    }
                    if let Some(addresses) = hints.get(cmux_remote::provider::ROUTING_DIRECT_ADDRS)
                    {
                        query.append_pair("direct_addrs", addresses);
                    }
                }
                push_unique_route(&mut routes, route_url.to_string());
                Some(route.node_id().to_string())
            } else {
                None
            };
            #[cfg(not(feature = "iroh-transport"))]
            let iroh_node_id = None;
            if let Some(route) = websocket_route {
                push_unique_route(&mut routes, route);
            }
            // Unix is fastest on the same host, and clients promote it when its
            // socket exists locally. Keeping it last avoids exporting a remote
            // host's filesystem path as the default route for mobile clients.
            push_unique_route(&mut routes, unix_route);

            let admin = serve_admin_with_mux_binding(
                daemon,
                &admin_socket,
                routes.clone(),
                Some(lifecycle_id.clone()),
                Some(owner_shutdown),
                Some(mux_binding.clone()),
            )
            .await?;
            let info = DaemonRuntimeInfo {
                session: options.session,
                state_dir: state_dir.clone(),
                link_socket: link_socket.clone(),
                admin_socket: admin_socket.clone(),
                daemon_fingerprint: auth.identity().fingerprint(),
                routes,
                direct_websocket: websocket.as_ref().map(|server| server.local_addr()),
                iroh_node_id,
                lifecycle_id: Some(lifecycle_id.clone()),
                replaceable_sidecar: options.replaceable_sidecar,
            };
            persist_runtime_info(&state_dir, &info)?;
            Ok((unix, websocket, workspace_http, relays, iroh, admin, info))
        }
        .await;
        let (unix, websocket, workspace_http, relays, _iroh, admin, info) = match transport_setup {
            Ok(transports) => transports,
            Err(error) => {
                return finalize_daemon_authorization(auth, state_dir, lifecycle_id, vec![error])
                    .await;
            }
        };
        #[cfg(test)]
        pause_daemon_cleanup(&state_dir, DaemonCleanupPausePhase::BeforeReadySend);
        let mut shutdown_failures = Vec::new();
        if ready.send(Ok(info)).is_ok() {
            // A Cloud machine's carrier (a grant config) also bridges the
            // acpmux service to this user's acpmux carrier socket, in the
            // home `cmux acp` resolves.
            #[cfg(unix)]
            let acpmux_socket = options
                .carrier_grant_config
                .as_ref()
                .and_then(|_| crate::acp::daemon_acpmux_home())
                .map(|home| cmux_remote::acpmux_bridge::socket_path(&home));
            #[cfg(not(unix))]
            let acpmux_socket = None;
            let services = DaemonServices::with_carrier_sockets(
                workspace,
                Some(mux_socket),
                options.local_sockets.clone(),
                acpmux_socket,
            );
            services.run_with_shutdown(clients, shutdown).await;
        } else {
            shutdown_failures.push(anyhow!("daemon owner stopped during startup"));
        }

        if let Err(error) = admin.shutdown().await {
            shutdown_failures
                .push(anyhow::Error::new(error).context("admin listener shutdown failed"));
        }
        if let Some(server) = workspace_http
            && let Err(error) = server.shutdown().await
        {
            shutdown_failures
                .push(anyhow::Error::new(error).context("workspace HTTP shutdown failed"));
        }
        #[cfg(feature = "iroh-transport")]
        if let Some(listener) = _iroh
            && let Err(error) = listener.shutdown().await
        {
            shutdown_failures
                .push(anyhow::Error::new(error).context("Iroh listener shutdown failed"));
        }
        for registration in relays {
            shutdown_relay(registration).await;
        }
        if let Some(server) = websocket
            && let Err(error) = server.shutdown().await
        {
            shutdown_failures
                .push(anyhow::Error::new(error).context("WebSocket server shutdown failed"));
        }
        if let Err(error) = unix.shutdown().await {
            shutdown_failures
                .push(anyhow::Error::new(error).context("Unix listener shutdown failed"));
        }
        finalize_daemon_authorization(auth, state_dir, lifecycle_id, shutdown_failures).await
    }
    .await;

    if let Err(error) = &setup {
        let _ = ready.send(Err(format!("{error:#}")));
    }
    setup
}

/// Installs the carrier grant verifier from `path`. A config that cannot be
/// read leaves grants refused (the daemon's default) and says why; the
/// daemon still serves every other route.
fn install_grant_verifier(auth: &AuthDatabase, path: &Path) {
    let installed = cmux_remote::grant::FileGrantVerifier::load(path).and_then(|verifier| {
        let verifier = verifier.with_unknown_kid_hook(Box::new(report_unknown_kid));
        let machine = verifier.config().machine.clone();
        auth.set_grant_verifier(Arc::new(verifier))
            .map(|()| machine)
            .map_err(|error| error.to_string())
    });
    match installed {
        Ok(machine) => {
            crate::client_log::stderr_log!(
                "remote",
                "{BIN}: carrier grants admitted for {machine}"
            );
        }
        Err(error) => {
            crate::client_log::stderr_log!("remote", "{BIN}: carrier grants refused ({error})");
        }
    }
}

/// Tells the Cloud agent a carrier grant named a kid this daemon's keyset
/// lacks, so it fetches the keyset and rewrites the grant config
/// (cmux-host `cloud/carrier_keyset.rs`). One line on the agent socket, on
/// its own thread so a handshake never waits; every step is bounded by
/// [`UNKNOWN_KID_REPORT_TIMEOUT`], and the verifier reports at most once a
/// minute.
fn report_unknown_kid(kid: &str) {
    let key = cmux_host::cloud::carrier_keyset::REQUEST_KEY;
    let line = format!("{}\n", serde_json::json!({ key: { "kid": kid } }));
    let spawned = thread::Builder::new().name("carrier-keyset-report".into()).spawn(move || {
        use std::io::{Read as _, Write as _};
        let socket = cmux_host::cloud::wire::AGENT_SOCKET;
        let Ok(mut stream) = std::os::unix::net::UnixStream::connect(socket) else { return };
        let _ = stream.set_write_timeout(Some(UNKNOWN_KID_REPORT_TIMEOUT));
        let _ = stream.set_read_timeout(Some(UNKNOWN_KID_REPORT_TIMEOUT));
        if stream.write_all(line.as_bytes()).is_ok() {
            let mut reply = [0_u8; 256];
            let _ = stream.read(&mut reply);
        }
    });
    if let Err(error) = spawned {
        crate::client_log::stderr_log!("remote", "{BIN}: carrier keyset report: {error}");
    }
}

/// Each step of an unknown-kid report (connect is local and immediate).
const UNKNOWN_KID_REPORT_TIMEOUT: Duration = Duration::from_secs(2);

pub(super) async fn load_daemon_auth_during_handoff(
    state_dir: &Path,
    daemon_name: &str,
    shutdown: &mut watch::Receiver<bool>,
    retry_timeout: Duration,
) -> anyhow::Result<Arc<AuthDatabase>> {
    let deadline = tokio::time::Instant::now() + retry_timeout;
    loop {
        match AuthDatabase::load_or_create(state_dir, daemon_name.to_owned(), true) {
            Ok(auth) => return Ok(auth),
            Err(IdentityError::Io(error)) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if *shutdown.borrow() {
                    return Err(anyhow!("remote daemon startup was cancelled"));
                }
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    return Err(anyhow::Error::new(IdentityError::Io(error)).context(
                        "remote daemon authorization state is still owned by another process",
                    ));
                }
                tokio::select! {
                    _ = tokio::time::sleep(
                        DAEMON_AUTH_LEASE_RETRY_INTERVAL.min(remaining)
                    ) => {}
                    _ = wait_for_shutdown(shutdown) => {
                        return Err(anyhow!("remote daemon startup was cancelled"));
                    }
                }
            }
            Err(error) => return Err(error.into()),
        }
    }
}

fn combine_shutdown_failures(mut failures: Vec<anyhow::Error>) -> anyhow::Result<()> {
    match failures.len() {
        0 => Ok(()),
        1 => Err(failures.pop().expect("one shutdown failure is present")),
        _ => Err(anyhow!(
            "remote daemon shutdown encountered multiple failures: {}",
            failures.into_iter().map(|error| format!("{error:#}")).collect::<Vec<_>>().join("; ")
        )),
    }
}

pub(super) async fn finish_daemon_shutdown(
    mut transport_failures: Vec<anyhow::Error>,
    authorization_finalization: impl Future<Output = Result<(), IdentityError>>,
) -> anyhow::Result<()> {
    if let Err(error) = authorization_finalization.await {
        transport_failures.push(
            anyhow::Error::new(error).context(catalog().remote.authorization_finalization_failed),
        );
    }
    combine_shutdown_failures(transport_failures)
}

async fn finalize_daemon_authorization(
    auth: Arc<AuthDatabase>,
    state_dir: PathBuf,
    lifecycle_id: String,
    transport_failures: Vec<anyhow::Error>,
) -> anyhow::Result<()> {
    let cleanup_state_dir = state_dir.clone();
    let authorization_finalization = auth.shutdown_with_cleanup(move |finalization| {
        #[cfg(test)]
        pause_daemon_cleanup(&cleanup_state_dir, DaemonCleanupPausePhase::BeforeAuthRelease);
        let status = if finalization.is_ok() {
            DaemonShutdownStatus::Succeeded
        } else {
            DaemonShutdownStatus::Failed
        };
        finalize_daemon_lifecycle(&cleanup_state_dir, &lifecycle_id, status)
    });
    let result = finish_daemon_shutdown(transport_failures, authorization_finalization).await;
    #[cfg(test)]
    pause_daemon_cleanup(&state_dir, DaemonCleanupPausePhase::AfterAuthShutdown);
    result
}

pub(super) fn push_unique_route(routes: &mut Vec<String>, route: String) {
    if !routes.iter().any(|existing| existing == &route) {
        routes.push(route);
    }
}

async fn shutdown_relay(registration: RelayDaemonRegistration) {
    registration.shutdown().await;
}
