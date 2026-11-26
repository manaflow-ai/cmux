//! [`Incoming`]: what serves a circuit that reaches this machine, by the service its first
//! record names, split from `hub_carrier.rs`.

use super::*;

pub(crate) struct Incoming {
    pub(super) carrier: Arc<HubCarrier>,
    pub(super) websocket: SocketAddr,
    pub(super) allowed: Arc<RwLock<HashSet<[u8; 32]>>>,
}

impl Incoming {
    /// The connection to this machine's cmux-tui remote daemon on `port`, as its gate admits.
    pub(super) async fn cmux_tui(
        &self,
        port: u16,
    ) -> Result<tokio::net::TcpStream, ServiceRefusal> {
        let gate = self.carrier.cmux_tui_gate().ok_or_else(|| {
            ServiceRefusal::new(
                "service.off",
                "this machine does not serve its cmux-tui remote daemon to its other machines",
            )
        })?;
        let target = gate.admit(port).await?;
        let daemon = tokio::net::TcpStream::connect(target).await.map_err(|e| {
            ServiceRefusal::new(
                "service.unreachable",
                format!("the cmux-tui remote daemon at {target} is not listening: {e}"),
            )
        })?;
        let _ = daemon.set_nodelay(true);
        Ok(daemon)
    }

    /// This machine's end of a machine-call circuit from `from`, or why it may not have one.
    pub(super) async fn machine_call(
        &self,
        from: Option<String>,
    ) -> Result<HubStream, ServiceRefusal> {
        match (self.carrier.machine_call_gate(), from) {
            (Some(gate), Some(from)) => gate.open(&from).await,
            (None, _) => Err(ServiceRefusal::new(
                "service.off",
                "this machine runs no calls for its other machines",
            )),
            (Some(_), None) => Err(ServiceRefusal::new(
                "service.unknown_machine",
                "the circuit's machine key is not one this machine admitted",
            )),
        }
    }

    /// This machine's end of a move's page circuit from `from` and the transfer gate's serving
    /// of the other end (the caller runs it beside the stream), or why it may not have one.
    pub(super) async fn transfer(
        &self,
        from: Option<String>,
    ) -> Result<(HubStream, impl Future<Output = ()> + Send + use<>), ServiceRefusal> {
        match (self.carrier.transfer_gate(), from) {
            (Some(gate), Some(from)) => {
                gate.admit(&from).await?;
                let (ours, theirs) = tokio::io::duplex(DUPLEX_BYTES);
                Ok((ours, async move { gate.serve(from, theirs).await }))
            }
            (None, _) => Err(ServiceRefusal::new(
                "service.off",
                "this machine serves no move pages to its other machines",
            )),
            (Some(_), None) => Err(ServiceRefusal::new(
                "service.unknown_machine",
                "the circuit's machine key is not one this machine admitted",
            )),
        }
    }

    /// The session socket a circuit from `from` (its proven key) may reach, as the session gate
    /// admits.
    pub(super) async fn admit_session(
        &self,
        from: Option<String>,
    ) -> Result<std::path::PathBuf, ServiceRefusal> {
        match (self.carrier.session_gate(), from) {
            (Some(gate), Some(from)) => gate.admit(&from).await,
            (None, _) => Err(ServiceRefusal::new(
                "service.off",
                "this machine does not open workspaces for its other machines",
            )),
            (Some(_), None) => Err(ServiceRefusal::new(
                "service.unknown_machine",
                "the circuit's machine key is not one this machine admitted",
            )),
        }
    }
}

#[async_trait]
impl RelayIncoming for Incoming {
    async fn incoming(self: Arc<Self>, link: Box<dyn FrameLink>) {
        self.accept(link, NetworkPeer::Relay).await;
    }
}

impl Incoming {
    /// A circuit from the relay or a direct connection (`peer`): the Noise handshake against
    /// the admitted keys, then the service its first record names.
    pub(super) async fn accept(self: Arc<Self>, link: Box<dyn FrameLink>, peer: NetworkPeer) {
        let keys = PeerKeys(self.allowed.read().unwrap_or_else(|e| e.into_inner()).clone());
        let identity = self.carrier.identity();
        let accepted = tokio::time::timeout(
            self.carrier.timings.handshake,
            accept_secure_link(link, &identity, &keys, InboundAuthEvidence::Network(peer)),
        )
        .await;
        let accepted = match accepted {
            Ok(Ok(accepted)) => accepted,
            Ok(Err(e)) => {
                tracing::debug!("hub carrier: a circuit was refused: {e}");
                return;
            }
            Err(_) => return,
        };
        // The dialer's key as the handshake proved it (its grant names the key's fingerprint).
        let from = keys
            .0
            .iter()
            .find(|key| public_key_fingerprint(key) == accepted.grant.device_id)
            .map(|key| base64::engine::general_purpose::STANDARD.encode(key));
        let link = accepted.link;
        // The acpmux listener is reached at once, as before services were named: a circuit with
        // no hello may send nothing for a while, and its listener counts it from the start. A
        // session circuit never uses it, so one that fails to connect refuses only the others.
        let listener = tokio::net::TcpStream::connect(self.websocket).await.ok();
        if let Some(listener) = &listener {
            let _ = listener.set_nodelay(true);
        }
        // The first record says which service the circuit is for: a hello names one, anything
        // else is the acpmux listener's own first bytes (a WebSocket upgrade).
        let first = match link.receive().await {
            Ok(Some(first)) => first,
            _ => {
                let _ = link.close().await;
                return;
            }
        };
        if mux::is_mux_hello(&first) && self.carrier.serves_kept.load(Ordering::SeqCst) {
            // A kept circuit: each stream names its own service and is admitted on its own.
            drop(listener);
            if link.send(service_answer(&Ok(()))).await.is_err() {
                let _ = link.close().await;
                return;
            }
            let stats = self.carrier.stats.clone();
            mux::serve(Box::new(link), self, from, stats).await;
            return;
        }
        if named_service(&first) == Some(Ok(CircuitService::MachineCall)) {
            // A machine-call circuit is answered in this process; the acpmux listener's
            // connection closes unused.
            drop(listener);
            let local = match self.machine_call(from).await {
                Ok(local) => local,
                Err(refusal) => {
                    tracing::info!("hub carrier: a machine-call circuit was refused: {refusal}");
                    let _ = link.send(service_answer(&Err(refusal))).await;
                    let _ = link.close().await;
                    return;
                }
            };
            if link.send(service_answer(&Ok(()))).await.is_err() {
                let _ = link.close().await;
                return;
            }
            self.carrier.stats.accepted.fetch_add(1, Ordering::Relaxed);
            pump(Box::new(link), local, &self.carrier.stats).await;
            return;
        }
        if named_service(&first) == Some(Ok(CircuitService::CmuxTuiSession)) {
            // A session circuit reaches the cmux-tui session socket; the acpmux listener's
            // connection closes unused.
            drop(listener);
            let admitted = self.admit_session(from).await;
            let local = match admitted {
                Ok(socket) => connect_session(&socket).await.map_err(|e| {
                    ServiceRefusal::new(
                        "service.unreachable",
                        format!("this machine's cmux-tui session is not running: {e}"),
                    )
                }),
                Err(refusal) => Err(refusal),
            };
            let local = match local {
                Ok(local) => local,
                Err(refusal) => {
                    tracing::info!("hub carrier: a session circuit was refused: {refusal}");
                    let _ = link.send(service_answer(&Err(refusal))).await;
                    let _ = link.close().await;
                    return;
                }
            };
            if link.send(service_answer(&Ok(()))).await.is_err() {
                let _ = link.close().await;
                return;
            }
            self.carrier.stats.accepted.fetch_add(1, Ordering::Relaxed);
            pump(Box::new(link), local, &self.carrier.stats).await;
            return;
        }
        if named_service(&first) == Some(Ok(CircuitService::TransferSource)) {
            // A move's pages: served in process, never through the WebSocket listener.
            drop(listener);
            let admitted = match (self.carrier.transfer_gate(), from.as_deref()) {
                (Some(gate), Some(from)) => gate.admit(from).await.map(|()| gate),
                (None, _) => Err(ServiceRefusal::new(
                    "service.off",
                    "this machine serves no move pages to its other machines",
                )),
                (Some(_), None) => Err(ServiceRefusal::new(
                    "service.unknown_machine",
                    "the circuit's machine key is not one this machine admitted",
                )),
            };
            let gate = match admitted {
                Ok(gate) => gate,
                Err(refusal) => {
                    tracing::info!("hub carrier: a transfer circuit was refused: {refusal}");
                    let _ = link.send(service_answer(&Err(refusal))).await;
                    let _ = link.close().await;
                    return;
                }
            };
            if link.send(service_answer(&Ok(()))).await.is_err() {
                let _ = link.close().await;
                return;
            }
            self.carrier.stats.accepted.fetch_add(1, Ordering::Relaxed);
            let (ours, theirs) = tokio::io::duplex(DUPLEX_BYTES);
            let from = from.unwrap_or_default();
            // Both end together: the link's end shuts `ours`, which ends the server's reads, and
            // the server's end drops `theirs`, which ends the pump's.
            tokio::join!(gate.serve(from, theirs), pump(Box::new(link), ours, &self.carrier.stats));
            return;
        }
        let Some(mut local) = listener else {
            let _ = link.close().await;
            return;
        };
        let started = match named_service(&first) {
            None => local.write_all(&first).await.map_err(|e| e.to_string()),
            Some(named) => {
                let reached = match named {
                    Ok(CircuitService::Acpmux) => Ok(local),
                    Ok(CircuitService::CmuxTui { port }) => self.cmux_tui(port).await,
                    // Served above; never reaches a TCP target. A held pipe and the broker
                    // ride only a kept circuit's stream, whose mux serves them.
                    Ok(
                        CircuitService::CmuxTuiResume { .. }
                        | CircuitService::CmuxTuiSession
                        | CircuitService::MachineCall
                        | CircuitService::TransferSource
                        | CircuitService::LaneGhBroker
                        | CircuitService::DirectOffer,
                    ) => Err(ServiceRefusal::new("service.unknown", "no such service")),
                    Err(refusal) => Err(refusal),
                };
                match reached {
                    // For cmux-tui, the acpmux listener's connection closes unused.
                    Ok(reached) => {
                        local = reached;
                        link.send(service_answer(&Ok(()))).await.map_err(|e| e.to_string())
                    }
                    Err(refusal) => {
                        tracing::info!("hub carrier: a circuit's service was refused: {refusal}");
                        let _ = link.send(service_answer(&Err(refusal))).await;
                        let _ = link.close().await;
                        return;
                    }
                }
            }
        };
        if started.is_err() {
            let _ = link.close().await;
            return;
        }
        self.carrier.stats.accepted.fetch_add(1, Ordering::Relaxed);
        pump(Box::new(link), local, &self.carrier.stats).await;
    }
}

/// A connection to this machine's own cmux-tui session socket (unix only; elsewhere none).
#[cfg(unix)]
pub(super) async fn connect_session(
    path: &std::path::Path,
) -> std::io::Result<tokio::net::UnixStream> {
    tokio::net::UnixStream::connect(path).await
}
#[cfg(not(unix))]
pub(super) async fn connect_session(
    _path: &std::path::Path,
) -> std::io::Result<tokio::io::DuplexStream> {
    Err(std::io::Error::from(std::io::ErrorKind::Unsupported))
}
