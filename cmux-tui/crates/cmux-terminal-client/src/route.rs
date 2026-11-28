//! Route connection: resolving an Iroh or WebSocket route, picking the enrolled daemon and connecting.

use super::*;

pub(super) fn resolve_iroh_route(route: &str) -> Result<(Url, BTreeMap<String, String>), String> {
    let mut endpoint = Url::parse(route).map_err(|error| format!("Iroh route: {error}"))?;
    if endpoint.scheme() != "iroh" {
        return Err("route is not an Iroh URL".into());
    }
    let node_id =
        endpoint.host_str().ok_or_else(|| "Iroh route has no node id".to_string())?.to_string();
    let query = endpoint.query_pairs().into_owned().collect::<Vec<_>>();
    endpoint.set_query(None);
    let mut routing = BTreeMap::from([(ROUTING_NODE_ID.into(), node_id)]);
    for (key, value) in query {
        let key = match key.as_str() {
            "node_id" => ROUTING_NODE_ID,
            "relay" | "relay_url" => ROUTING_RELAY_URL,
            "direct" | "direct_addrs" => ROUTING_DIRECT_ADDRS,
            _ => return Err("Iroh route contains an unsupported parameter".into()),
        };
        routing.entry(key.into()).or_insert(value);
    }
    Ok((endpoint, routing))
}

/// Pick the enrolled daemon a bare route refers to, the way the sidecar does:
/// the one whose route hints contain this route, or the only one known.
pub(super) fn select_enrolled_daemon(
    daemons: Vec<KnownDaemon>,
    route: &str,
) -> Result<KnownDaemon, String> {
    let hint = credential_free_route_hint(route).map_err(|error| error.to_string())?;
    let matching = daemons
        .iter()
        .filter(|daemon| daemon.route_hints.iter().any(|known| known == &hint))
        .cloned()
        .collect::<Vec<_>>();
    let selected = match matching.as_slice() {
        [daemon] => daemon.clone(),
        [] if daemons.len() == 1 => daemons[0].clone(),
        [] => {
            return Err("no enrolled daemon matches this route; connect with an invitation".into());
        }
        _ => return Err("multiple enrolled daemons match this route".into()),
    };
    if selected.auth == KnownDaemonAuth::Carrier {
        return Err("this daemon was enrolled through a trusted carrier, not a device key".into());
    }
    Ok(selected)
}

/// Carrier authentication is only valid on the authenticated private tunnel.
/// Requiring a literal in AllowedIPs also prevents the WireGuard dialer's
/// ordinary OS fallback (or a second DNS resolution) from weakening this gate.
pub(super) fn validate_trusted_route(
    route: &Url,
    routes: Option<&[IpNetwork]>,
) -> Result<(), String> {
    let routes =
        routes.ok_or_else(|| "trusted Cloud route requires a WireGuard tunnel".to_string())?;
    if !matches!(route.scheme(), "ws" | "wss") {
        return Err("trusted Cloud route must use a WebSocket inside WireGuard".into());
    }
    let address: std::net::IpAddr = match route.host() {
        Some(url::Host::Ipv4(address)) => address.into(),
        Some(url::Host::Ipv6(address)) => address.into(),
        _ => return Err("trusted Cloud route must use a literal tunnel IP address".into()),
    };
    if !routes.iter().any(|network| network.contains(address)) {
        return Err("trusted Cloud route is outside the WireGuard tunnel".into());
    }
    Ok(())
}

pub(super) async fn connect_route_client(
    options: RouteConnectOptions<'_>,
) -> Result<RouteConnection, String> {
    let RouteConnectOptions {
        route,
        state_dir,
        device_name,
        invitation_uri,
        trusted_carrier,
        wireguard,
    } = options;
    let parsed = Url::parse(route).map_err(|error| format!("route: {error}"))?;
    if trusted_carrier {
        validate_trusted_route(&parsed, wireguard.as_ref().map(|net| net.routes()))?;
        if invitation_uri.is_some() {
            return Err("trusted Cloud route cannot also use an invitation".into());
        }
    }
    let store = ClientIdentityStore::load_or_create(state_dir)
        .map_err(|error| format!("client identity: {error}"))?;
    let invitation = invitation_uri
        .map(|uri| {
            EnrollmentInvitation::from_uri(uri).map_err(|error| format!("invitation: {error}"))
        })
        .transpose()?;

    let (transport, endpoint, routing): (ClientTransport, Url, BTreeMap<String, String>) =
        match parsed.scheme() {
            "iroh" => {
                let (endpoint, routing) = resolve_iroh_route(route)?;
                let provider = Arc::new(
                    IrohProvider::new(IrohProviderConfig {
                        discovery_n0: true,
                        ..IrohProviderConfig::default()
                    })
                    .map_err(|error| error.to_string())?,
                );
                (ClientTransport::Iroh(provider), endpoint, routing)
            }
            "ws" | "wss" => {
                let dialer: Arc<dyn Dialer> = match wireguard {
                    Some(net) => Arc::new(WireGuardDialer::new(net)),
                    None => Arc::new(OsTcpDialer),
                };
                let provider = Arc::new(DirectWebSocketProvider::with_dialer(
                    DIRECT_ROUTE_MAX_FRAME_BYTES,
                    dialer,
                ));
                (ClientTransport::Direct(provider), parsed.clone(), BTreeMap::new())
            }
            other => return Err(format!("unsupported route scheme {other:?}")),
        };

    let (auth, expected_daemon, known) = match &invitation {
        Some(invitation) => {
            let daemon_key: [u8; 32] = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(&invitation.daemon_public_key)
                .map_err(|error| format!("daemon key: {error}"))?
                .try_into()
                .map_err(|bytes: Vec<u8>| format!("daemon key is {} bytes", bytes.len()))?;
            let secret = invitation.secret_bytes().map_err(|error| error.to_string())?;
            (
                ClientAuthMode::Invitation {
                    id: invitation.id.clone(),
                    secret: Zeroizing::new(secret),
                },
                Some(daemon_key),
                None,
            )
        }
        None if trusted_carrier => (ClientAuthMode::Carrier, None, None),
        None => {
            let known = select_enrolled_daemon(store.known_daemons().await, route)?;
            let key = store
                .daemon_key(&known.fingerprint)
                .await
                .map_err(|error| error.to_string())?
                .ok_or_else(|| "enrolled daemon key is missing".to_string())?;
            (ClientAuthMode::Enrolled, Some(key), Some(known))
        }
    };

    let mut session_bytes = [0u8; 16];
    getrandom::fill(&mut session_bytes).map_err(|error| error.to_string())?;
    let session = SessionId(session_bytes);
    let group = match &transport {
        ClientTransport::Iroh(provider) => provider
            .connect(ConnectRequest {
                endpoint,
                session,
                lane_policy: LanePolicy::Isolated,
                routing,
            })
            .await
            .map_err(|error| format!("Iroh connect: {error}"))?,
        ClientTransport::Direct(provider) => provider
            .connect(ConnectRequest {
                endpoint,
                session,
                lane_policy: LanePolicy::Isolated,
                routing,
            })
            .await
            .map_err(|error| format!("direct connect: {error}"))?,
    };
    let connection = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: store.identity(),
            expected_daemon,
            auth,
            device_name: device_name.into(),
            session,
            lane_policy: LanePolicy::Isolated,
            limits: Default::default(),
            reconnect: ReconnectPolicy::default(),
        },
    )
    .await
    .map_err(|error| format!("Noise handshake: {error}"))?;

    // Remember the daemon so the next connect on this route needs no invitation.
    let remembered = match (&invitation, &known) {
        (Some(invitation), _) => {
            let mut hints = vec![route.to_string()];
            for hint in &invitation.route_hints {
                if !hints.contains(hint) {
                    hints.push(hint.clone());
                }
            }
            store
                .pin_daemon(invitation.daemon_name.clone(), connection.daemon_public_key(), hints)
                .await
                .map(|_| ())
        }
        (None, Some(known)) => {
            store.remember_verified_route(&known.fingerprint, route).await.map(|_| ())
        }
        (None, None) if trusted_carrier => store
            .pin_carrier_daemon(
                "Cloud machine".into(),
                connection.daemon_public_key(),
                vec![route.to_string()],
            )
            .await
            .map(|_| ()),
        (None, None) => Ok(()),
    };
    if let Err(error) = remembered {
        let _ = connection.close().await;
        return Err(format!("client state: {error}"));
    }

    let snapshot = connection.snapshot().await;
    let path = snapshot
        .transport
        .selected_path
        .as_ref()
        .map(|path| format!("{:?}", path.kind).to_lowercase())
        .unwrap_or_else(|| snapshot.transport.route.clone());
    let state = Arc::new(Mutex::new(
        ClientState::new(
            snapshot.transport.provider,
            path,
            snapshot.generation,
            unattached_terminal_id(),
        )
        .map_err(|error| format!("libghostty: {error}"))?,
    ));
    let multiplexer = ServiceMultiplexer::new(connection.clone(), EndpointRole::Client);
    Ok(RouteConnection { transport, connection, multiplexer, state })
}
