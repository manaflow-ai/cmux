//! Tailnet-only WSS ingress. The owning daemon supplies its existing Hub, so
//! mint, redemption and paired-device reconnects all use the same Pairing.
//! No dashboard token, LocalApp token or caller-supplied local target is accepted.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, ensure};
use cmux_tailnet::{BackendState, Node, Status, WhoIs};
use futures_util::{SinkExt, StreamExt};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
use rustls::server::{ClientHello, ResolvesServerCert};
use rustls::sign::CertifiedKey;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{Semaphore, mpsc, watch};
use tokio::task::JoinSet;
use tokio_tungstenite::tungstenite::{
    Message,
    handshake::server::{Request, Response},
    http,
};
use zeroize::Zeroizing;

use crate::hub::Hub;
use crate::pairing::{DeviceAuth, Role, TICKET_HEADER};

const HANDSHAKE_BOUND: Duration = Duration::from_secs(10);
const MAX_CONNECTIONS: usize = 64;

/// Serves this node's TCP 443 until `stop` is true or its sender is dropped.
/// Each accepted stream is owner-admitted before application bytes are read.
/// Shutdown closes the listener and all network streams, then lets the Hub
/// release connection subscriptions through its ordinary disconnect path.
pub async fn serve(
    hub: Arc<Hub>,
    node: Arc<Node>,
    fqdn: String,
    mut stop: watch::Receiver<bool>,
) -> Result<()> {
    let (restart, _draining) = hub.ws_shutdown.listener();
    ensure!(valid_name(&fqdn), "invalid tailnet DNS name");
    if *stop.borrow() || restart.is_requested() {
        return Ok(());
    }
    let listen_node = node.clone();
    let opening = tokio::task::spawn_blocking(move || listen_node.listen_tcp(443));
    let listener = tokio::select! {
        biased;
        () = restart.requested() => return Ok(()),
        () = restart.normal() => return Ok(()),
        _ = stopped(&mut stop) => return Ok(()),
        result = tokio::time::timeout(HANDSHAKE_BOUND, opening) => {
            let joined = result?;
            let listener = joined?;
            listener?
        },
    };
    let mut listener = tokio::io::unix::AsyncFd::new(listener)?;
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    let mut connections = JoinSet::new();
    let (close, closing) = watch::channel(false);
    let result = loop {
        tokio::select! {
            biased;
            () = restart.requested() => break Ok(()),
            () = restart.normal() => {
                restart.close_clients();
                break Ok(());
            },
            _ = stopped(&mut stop) => break Ok(()),
            Some(_) = connections.join_next(), if !connections.is_empty() => {},
            ready = listener.readable_mut() => {
                let mut ready = match ready { Ok(r) => r, Err(e) => break Err(e.into()) };
                let accepted = ready.try_io(|fd| {
                    fd.get_mut().try_accept()?.ok_or_else(|| std::io::Error::from(std::io::ErrorKind::WouldBlock))
                });
                let (stream, remote) = match accepted {
                    Err(_) => continue,
                    // Only a closed listener ends the ingress (the service then waits for an
                    // explicit retry); one lost connection or a descriptor shortage does not.
                    Ok(Err(e)) if super::accept_ends_listener(&e) => break Err(e.into()),
                    Ok(Err(e)) => {
                        tracing::warn!("tailnet accept failed: {e}");
                        tokio::time::sleep(super::accept_retry_delay(&e)).await;
                        continue;
                    }
                    Ok(Ok(accepted)) => accepted,
                };
                let Ok(slot) = slots.clone().try_acquire_owned() else { continue };
                let (node, hub, fqdn, mut stop) = (node.clone(), hub.clone(), fqdn.clone(), closing.clone());
                let restart = restart.clone();
                connections.spawn(async move {
                    let prepare = tokio::task::spawn_blocking(move || -> Result<_> {
                        let status = node.status()?;
                        ensure!(status.dns_name().as_deref() == Some(&fqdn), "tailnet name changed");
                        ensure!(owner_allowed(&status, &node.whois(&remote)?), "tailnet peer refused");
                        // Tailscale caches and renews this pair. Obtain it per admitted
                        // connection, so no timer or stale certificate survives a rename.
                        let pem = Zeroizing::new(node.certificate_pair(&fqdn)?);
                        // Keep capacity reserved even if the async timeout drops
                        // this task's handle before its bounded LocalAPI call ends.
                        Ok((tls_config(&fqdn, &pem)?, fqdn, slot))
                    });
                    let prepared = tokio::select! {
                        () = restart.closing() => return,
                        _ = stopped(&mut stop) => return,
                        result = tokio::time::timeout(HANDSHAKE_BOUND, prepare) => result,
                    };
                    let Ok(Ok(Ok((tls, fqdn, _slot)))) = prepared else { return };
                    if stream.set_nonblocking(true).is_err() { return }
                    let Ok(stream) = tokio::net::UnixStream::from_std(stream) else { return };
                    let _ = connection(hub, stream, tls, &fqdn, stop, restart).await;
                });
            }
        }
    };
    drop(listener);
    if restart.is_requested() {
        restart.close_clients();
    }
    close.send_replace(true);
    if tokio::time::timeout(super::ws_shutdown::DRAIN_BUDGET, async {
        while connections.join_next().await.is_some() {}
    })
    .await
    .is_err()
    {
        connections.abort_all();
        while connections.join_next().await.is_some() {}
    }
    result
}

fn valid_name(name: &str) -> bool {
    name.len() <= 253
        && name.ends_with(".ts.net")
        && name.split('.').all(|part| {
            !part.is_empty()
                && part.len() <= 63
                && !part.starts_with('-')
                && !part.ends_with('-')
                && part.bytes().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
        })
}

fn owner_allowed(me: &Status, peer: &WhoIs) -> bool {
    let (Some(owner), Some(user), Some(node)) = (me.owner(), &peer.user_profile, &peer.node) else {
        return false;
    };
    me.state() == BackendState::Running
        && owner.id > 0
        && owner.id == user.id
        && node.user == user.id
        && node.sharer == 0
        && !peer.is_tagged()
}

#[derive(Debug)]
struct ExactNameCertificate {
    name: String,
    key: Arc<CertifiedKey>,
}

impl ResolvesServerCert for ExactNameCertificate {
    fn resolve(&self, hello: ClientHello<'_>) -> Option<Arc<CertifiedKey>> {
        (hello.server_name() == Some(self.name.as_str())).then(|| self.key.clone())
    }
}

fn tls_config(fqdn: &str, pem: &[u8]) -> Result<Arc<rustls::ServerConfig>> {
    let certs = CertificateDer::pem_slice_iter(pem).collect::<std::result::Result<Vec<_>, _>>()?;
    ensure!(!certs.is_empty(), "tailnet certificate is missing");
    let private = PrivateKeyDer::from_pem_slice(pem).context("tailnet private key is missing")?;
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let key = Arc::new(CertifiedKey::from_der(certs, private, &provider)?);
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .with_no_client_auth()
        .with_cert_resolver(Arc::new(ExactNameCertificate { name: fqdn.into(), key }));
    Ok(Arc::new(config))
}

fn request_admission(hub: &Hub, fqdn: &str, request: &Request) -> Option<super::pairing::Admitted> {
    let headers = request.headers();
    let mut hosts = headers.get_all("host").iter();
    let host = hosts.next()?.to_str().ok()?;
    if hosts.next().is_some()
        || (host != fqdn && host != format!("{fqdn}:443"))
        || headers.contains_key("origin")
        || request.uri().path() != "/"
        || request.uri().query().is_some()
    {
        return None;
    }
    // Ambiguous credentials fail closed; only the ticket header or one
    // paired-device Authorization header is meaningful on this transport.
    let mut tickets = headers.get_all(TICKET_HEADER).iter();
    if let Some(ticket) = tickets.next() {
        if tickets.next().is_some() || headers.contains_key("authorization") {
            return None;
        }
        let secret = ticket.to_str().ok()?;
        return hub
            .pairing
            .ticket_open_bound(secret, hub.person.instance())
            .then(|| super::pairing::Admitted::Ticket(secret.to_owned()));
    }
    let mut authorizations = headers.get_all("authorization").iter();
    let token = cmux_local_auth::bearer_token(authorizations.next()?.to_str().ok()?)?;
    if authorizations.next().is_some() {
        return None;
    }
    let device = hub.pairing.device_for(token)?;
    matches!(device.role, Role::Client | Role::ReadOnly)
        .then_some(super::pairing::Admitted::Device(device))
}

async fn stopped(stop: &mut watch::Receiver<bool>) {
    while !*stop.borrow_and_update() {
        if stop.changed().await.is_err() {
            break;
        }
    }
}

async fn connection<S>(
    hub: Arc<Hub>,
    stream: S,
    tls: Arc<rustls::ServerConfig>,
    fqdn: &str,
    mut stop: watch::Receiver<bool>,
    restart: super::WsShutdown,
) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let mut admitted = None;
    let handshake = async {
        let stream = tokio_rustls::TlsAcceptor::from(tls).accept(stream).await?;
        let callback = |request: &Request, response: Response| {
            admitted = request_admission(&hub, fqdn, request);
            if admitted.is_some() {
                Ok(response)
            } else {
                let mut refusal = http::Response::new(Some("tailnet admission refused".to_owned()));
                *refusal.status_mut() = http::StatusCode::FORBIDDEN;
                Err(refusal)
            }
        };
        Ok::<_, anyhow::Error>(
            tokio_tungstenite::accept_hdr_async_with_config(
                stream,
                callback,
                Some(super::ws_config()),
            )
            .await?,
        )
    };
    let mut ws = tokio::select! {
        biased;
        () = restart.closing() => return Ok(()),
        _ = stopped(&mut stop) => return Ok(()),
        result = tokio::time::timeout(HANDSHAKE_BOUND, handshake) => result??,
    };
    match admitted.ok_or_else(|| anyhow!("tailnet admission missing"))? {
        super::pairing::Admitted::Ticket(secret) => {
            let close = tokio::select! {
                biased;
                () = restart.normal() => Some(false),
                () = restart.closing() => Some(true),
                _ = stopped(&mut stop) => Some(false),
                _ = super::pairing::serve_redeem(hub, &mut ws, secret) => None,
            };
            if let Some(restarting) = close {
                super::ws_shutdown::close(&mut ws, restarting).await;
            }
        }
        super::pairing::Admitted::Device(device) => {
            device_connection(hub, ws, device, stop, restart).await
        }
        super::pairing::Admitted::Dashboard => {
            return Err(anyhow!("tailnet refuses dashboard tokens"));
        }
    }
    Ok(())
}

async fn device_connection<S>(
    hub: Arc<Hub>,
    ws: tokio_tungstenite::WebSocketStream<S>,
    device: DeviceAuth,
    mut stop: watch::Receiver<bool>,
    restart: super::WsShutdown,
) where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let _open = hub.pairing.opened(&device.id);
    let revoked = hub.pairing.revoked(&device.id);
    let (mut sink, mut source) = ws.split();
    let (input, incoming) = mpsc::channel(256);
    let (output, mut outgoing) = mpsc::channel::<String>(4096);
    // The network pump owns the only inbound sender. Any close, revoke or
    // stop drops it, allowing the Hub's ordinary cleanup to finish.
    let transport = async move {
        let network = async {
            loop {
                tokio::select! {
                    frame = source.next() => match frame {
                        Some(Ok(Message::Text(text))) => {
                            if input.send(text.to_string()).await.is_err() { break }
                        }
                        Some(Ok(Message::Ping(bytes))) => {
                            if sink.send(Message::Pong(bytes)).await.is_err() { break }
                        }
                        Some(Ok(Message::Pong(_))) => {},
                        // Binary uploads are a LocalApp-only protocol.
                        _ => break,
                    },
                    line = outgoing.recv() => {
                        let Some(line) = line else { break };
                        if sink.send(Message::Text(line.trim_end_matches('\n').to_owned().into())).await.is_err() { break }
                    }
                }
            }
        };
        let restarting = tokio::select! {
            biased;
            () = restart.normal() => false,
            () = restart.closing() => true,
            _ = stopped(&mut stop) => false,
            _ = revoked => false,
            _ = network => false,
        };
        super::ws_shutdown::close(&mut sink, restarting).await;
        drop(input);
    };
    tokio::join!(transport, super::serve_connection_device(hub, incoming, output, device));
}

#[cfg(test)]
#[path = "tailnet_ingress_tests.rs"]
mod tests;
