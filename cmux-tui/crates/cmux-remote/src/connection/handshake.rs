//! Establish one attempt's physical links: authenticate each link and read the daemon's welcome.

use super::*;

/// One attempt's links, and what their welcomes said.
pub(super) struct Established {
    pub(super) link: LaneMuxLink,
    pub(super) daemon_key: [u8; 32],
    pub(super) daemon_resume: BTreeMap<Lane, u64>,
    pub(super) daemon_takes_ik: bool,
    pub(super) daemon_takes_early_data: bool,
}

/// The early data for a link carrying `lanes`: the Control link's, none for the rest.
fn early_for(lanes: &[Lane], early: &[Bytes]) -> Vec<Bytes> {
    if lanes.contains(&Lane::Control) { early.to_vec() } else { Vec::new() }
}

pub(super) async fn establish_physical_links(
    group: Arc<dyn LinkGroup>,
    config: &ClientConnectionConfig,
    generation: u64,
    resume: BTreeMap<Lane, u64>,
    daemon_takes_ik: bool,
    early: Vec<Bytes>,
) -> Result<Established, ConnectionError> {
    let mut connection_attempt = [0_u8; 16];
    getrandom::fill(&mut connection_attempt)
        .map_err(|error| ConnectionError::Crypto(CryptoError::Random(error.to_string())))?;
    let connection_attempt = ConnectionAttemptId(connection_attempt);
    let bindings = lane_bindings(config.lane_policy, group.capabilities());
    let subsequent_auth = match config.auth {
        ClientAuthMode::Invitation { .. } => ClientAuthMode::Enrolled,
        ref other => other.clone(),
    };
    // A reconnect that pins the daemon's key and holds its IK offer learns nothing from its
    // first link's welcome, so every lane link opens at once: the reconnect costs one link's
    // setup, not two in a row (`cmux_braid_session::open_lanes_at_once`).
    if let Some(pinned) = config.expected_daemon.filter(|_| {
        cmux_braid_session::open_lanes_at_once(LinkFacts {
            invitation: matches!(config.auth, ClientAuthMode::Invitation { .. }),
            pinned_peer: true,
            peer_takes_ik: daemon_takes_ik,
            carries_bearer_secret: matches!(config.auth, ClientAuthMode::Grant { .. }),
        })
    }) {
        let context = LinkHandshakeContext {
            generation,
            expected_daemon: Some(pinned),
            connection_attempt,
            daemon_takes_ik,
        };
        let mut pending = bindings
            .into_iter()
            .enumerate()
            .map(|(index, lanes)| {
                let auth = if index == 0 { config.auth.clone() } else { subsequent_auth.clone() };
                let early = early_for(&lanes, &early);
                let link = authenticate_one(
                    group.clone(),
                    config,
                    auth,
                    lanes,
                    resume.clone(),
                    context,
                    early,
                );
                async move { (index, link.await) }
            })
            .collect::<FuturesUnordered<_>>();
        let mut opened = Vec::new();
        let mut daemon_resume = None;
        // Every welcome has to offer IK (and early data) for the next reconnect to keep it.
        let mut takes_ik = true;
        let mut takes_early = true;
        while let Some((index, result)) = pending.next().await {
            let (lanes, link, link_resume) = result?;
            if daemon_resume.get_or_insert_with(|| link_resume.clone()) != &link_resume {
                return Err(ConnectionError::Protocol(
                    "daemon reported inconsistent resume cursors across lane links".into(),
                ));
            }
            takes_ik &= link.peer_takes_ik();
            takes_early &= link.peer_takes_early_data();
            opened.push((index, LinkRoute { lanes, link: Arc::new(link) }));
        }
        opened.sort_by_key(|(index, _)| *index);
        let routes = opened.into_iter().map(|(_, route)| route).collect();
        let link = LaneMuxLink::new(format!("lanes+{}", group.description()), routes)?;
        return Ok(Established {
            link,
            daemon_key: pinned,
            daemon_resume: daemon_resume.unwrap_or_default(),
            daemon_takes_ik: takes_ik,
            daemon_takes_early_data: takes_early,
        });
    }
    let first_lanes = bindings.first().expect("lane bindings are never empty").clone();
    let first_early = early_for(&first_lanes, &early);
    let (_, first, daemon_resume) = authenticate_one(
        group.clone(),
        config,
        config.auth.clone(),
        first_lanes.clone(),
        resume.clone(),
        LinkHandshakeContext {
            generation,
            expected_daemon: config.expected_daemon,
            connection_attempt,
            daemon_takes_ik,
        },
        first_early,
    )
    .await?;
    let daemon_key = first.remote_static();
    // The first link's welcome is in: the rest of this attempt's links run IK if it offered it,
    // a first connect's included.
    let daemon_takes_ik = first.peer_takes_ik();
    let daemon_takes_early_data = first.peer_takes_early_data();
    let mut routes = vec![LinkRoute { lanes: first_lanes, link: Arc::new(first) }];

    let mut pending = FuturesUnordered::new();
    for lanes in bindings.into_iter().skip(1) {
        let link_early = early_for(&lanes, &early);
        pending.push(authenticate_one(
            group.clone(),
            config,
            subsequent_auth.clone(),
            lanes,
            resume.clone(),
            LinkHandshakeContext {
                generation,
                expected_daemon: Some(daemon_key),
                connection_attempt,
                daemon_takes_ik,
            },
            link_early,
        ));
    }
    while let Some(result) = pending.next().await {
        let (lanes, link, link_resume) = result?;
        if link_resume != daemon_resume {
            return Err(ConnectionError::Protocol(
                "daemon reported inconsistent resume cursors across lane links".into(),
            ));
        }
        routes.push(LinkRoute { lanes, link: Arc::new(link) });
    }
    let link = LaneMuxLink::new(format!("lanes+{}", group.description()), routes)?;
    Ok(Established { link, daemon_key, daemon_resume, daemon_takes_ik, daemon_takes_early_data })
}

#[derive(Clone, Copy)]
struct LinkHandshakeContext {
    generation: u64,
    expected_daemon: Option<[u8; 32]>,
    connection_attempt: ConnectionAttemptId,
    daemon_takes_ik: bool,
}

async fn authenticate_one(
    group: Arc<dyn LinkGroup>,
    config: &ClientConnectionConfig,
    auth: ClientAuthMode,
    lanes: Vec<Lane>,
    resume: BTreeMap<Lane, u64>,
    context: LinkHandshakeContext,
    early: Vec<Bytes>,
) -> Result<(Vec<Lane>, crate::crypto::SecureLink, BTreeMap<Lane, u64>), ConnectionError> {
    let primary = lanes[0];
    // Every step of a link's setup shares the attempt's deadline: opening the carrier (a direct
    // WebSocket's TCP, TLS and upgrade, a relay circuit), the Noise exchange, the daemon's welcome
    // and its link-ready. The clock starts before the open, so a carrier that accepts and then
    // never finishes opening fails this attempt (and the first connect, which has no outer
    // deadline of its own) instead of hanging it. A link that stalls after the Noise exchange
    // fails the attempt too (so it is retried), and cannot hand back a session the daemon dropped
    // meanwhile as an incomplete link group. An invitation is the exception: its welcome waits on
    // a person's approval, so only its open and its link-ready, once the welcome is in, have the
    // deadline.
    let timeout = config.reconnect.attempt_timeout;
    let timed_out = || ConnectionError::Crypto(CryptoError::HandshakeTimeout { timeout });
    let invitation = matches!(auth, ClientAuthMode::Invitation { .. });
    let started = tokio::time::Instant::now();
    let physical = tokio::time::timeout_at(
        started + timeout,
        group.open(LinkRequest { lane: primary, generation: context.generation }),
    )
    .await
    .map_err(|_| {
        ConnectionError::Provider(ProviderError::Link(LinkError::Transport(format!(
            "opening lane {primary} on {} did not finish within {}",
            group.description(),
            crate::provider::DisplaySeconds(timeout)
        ))))
    })??;
    let setup = initiate_secure_link(
        physical,
        ClientHandshake {
            identity: config.identity.clone(),
            expected_daemon: context.expected_daemon,
            auth,
            device_name: config.device_name.clone(),
            session: config.session,
            lane: primary,
            lanes: lanes.clone(),
            generation: context.generation,
            connection_attempt: context.connection_attempt,
            resume,
            daemon_takes_ik: context.daemon_takes_ik,
            early,
            handshake_timeout: config.reconnect.attempt_timeout,
        },
    );
    let (secure, deadline) = if invitation {
        let secure = setup.await?;
        (secure, tokio::time::Instant::now() + timeout)
    } else {
        let deadline = started + timeout;
        (tokio::time::timeout_at(deadline, setup).await.map_err(|_| timed_out())??, deadline)
    };
    let answer =
        tokio::time::timeout_at(deadline, receive_control::<LinkHandshakeResponse>(&secure))
            .await
            .map_err(|_| timed_out())?;
    let ready = match answer? {
        LinkHandshakeResponse::Ready(ready) => ready,
        LinkHandshakeResponse::Rejected(LinkRejected {
            rejected: LinkRejection::SessionUnavailable,
            ..
        }) => {
            return Err(ConnectionError::SessionUnavailable);
        }
        LinkHandshakeResponse::Rejected(LinkRejected {
            rejected: LinkRejection::TooManyClients,
            limit,
        }) => {
            return Err(ConnectionError::DaemonAtCapacity { limit });
        }
    };
    if ready.session != config.session || ready.generation != context.generation {
        return Err(ConnectionError::Protocol(
            "daemon link-ready metadata does not match the requested session".into(),
        ));
    }
    Ok((lanes, secure, ready.daemon_resume))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct LinkReady {
    session: SessionId,
    generation: u64,
    daemon_resume: BTreeMap<Lane, u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
enum LinkHandshakeResponse {
    Ready(LinkReady),
    Rejected(LinkRejected),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct LinkRejected {
    rejected: LinkRejection,
    /// The daemon's client limit, with [`LinkRejection::TooManyClients`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    limit: Option<usize>,
}

impl LinkRejected {
    pub(crate) fn session_unavailable() -> Self {
        Self { rejected: LinkRejection::SessionUnavailable, limit: None }
    }

    pub(crate) fn too_many_clients(limit: usize) -> Self {
        Self { rejected: LinkRejection::TooManyClients, limit: Some(limit) }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
enum LinkRejection {
    SessionUnavailable,
    /// The daemon already serves its limit of logical client sessions. A
    /// slot frees when one of them ends, so the client retries with backoff.
    TooManyClients,
}

pub(crate) async fn send_link_ready(
    link: &dyn FrameLink,
    session: SessionId,
    generation: u64,
    daemon_resume: BTreeMap<Lane, u64>,
) -> Result<(), ConnectionError> {
    let payload = serde_json::to_vec(&LinkReady { session, generation, daemon_resume })
        .map_err(|error| ConnectionError::Protocol(error.to_string()))?;
    link.send(Bytes::from(payload)).await?;
    Ok(())
}

pub(crate) async fn send_link_rejection(
    link: &dyn FrameLink,
    rejection: LinkRejected,
) -> Result<(), ConnectionError> {
    let payload = serde_json::to_vec(&rejection)
        .map_err(|error| ConnectionError::Protocol(error.to_string()))?;
    link.send(Bytes::from(payload)).await?;
    Ok(())
}

async fn receive_control<T: for<'de> Deserialize<'de>>(
    link: &dyn FrameLink,
) -> Result<T, ConnectionError> {
    let payload = link.receive().await?.ok_or(LinkError::Closed)?;
    serde_json::from_slice(&payload).map_err(|error| ConnectionError::Protocol(error.to_string()))
}

#[cfg(test)]
#[path = "link_rejection_tests.rs"]
mod link_rejection_tests;
