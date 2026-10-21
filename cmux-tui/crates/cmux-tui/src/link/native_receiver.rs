//! A VM's receiving mesh is addressed by host id. Its peers may source only
//! their install /128, and their service futures end before a WG peer goes away.
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::future::Future;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use cmux_host::cloud::receiver::ReceiverBinding;
use cmux_link::elapsed::Deadline;
use cmux_link::native_token::{NativePolicy, NativeTokenVerifier, PolicyDeadline};
use cmux_link::overlay_addr::overlay_address;
use cmux_wg::{
    InterfaceAddress, IpNetwork, WgMesh, WgMeshConfig, WgMeshListener, WgPeer, WgStream,
};
use futures_util::{StreamExt as _, stream::FuturesUnordered};
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, oneshot};
use zeroize::Zeroizing;

use super::host_inbound::{HostIdentity, serve_host_inbound};

const MAX_STREAMS: usize = 4096;
type ServiceTask = Pin<Box<dyn Future<Output = u64> + Send>>;

struct Service {
    peer: [u8; 32],
    stop: Option<oneshot::Sender<()>>,
}

/// The source owns the verifier and installs each authenticated snapshot before
/// sending its policy here. No caller hello or WG packet can publish a peer.
pub(super) struct NativeReceiver {
    binding: ReceiverBinding,
    session: PathBuf,
    sshd: SocketAddr,
    verifier: Arc<NativeTokenVerifier>,
    mesh: WgMesh,
    listener: WgMeshListener,
    peers: BTreeMap<[u8; 32], Ipv6Addr>,
    services: HashMap<u64, Service>,
    inflight: FuturesUnordered<ServiceTask>,
    serial: u64,
    expires: Option<(Instant, Option<Deadline>)>,
}

impl NativeReceiver {
    pub(super) async fn start(
        binding: ReceiverBinding,
        private: Zeroizing<[u8; 32]>,
        socket: UdpSocket,
        session: PathBuf,
        sshd: SocketAddr,
        verifier: Arc<NativeTokenVerifier>,
    ) -> anyhow::Result<Self> {
        let public = x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(*private));
        if STANDARD.encode(public.as_bytes()) != binding.wg_public_key {
            bail!("cloud.receiver.self_key_refused");
        }
        let mesh = WgMesh::start(
            WgMeshConfig {
                private_key: private,
                addresses: vec![InterfaceAddress {
                    address: IpAddr::V6(overlay_address(&binding.host)),
                    prefix: 128,
                }],
                mtu: super::state::LINK_MTU,
            },
            socket,
        )?;
        let listener = mesh.listen(cmux_link::LINK_PORT).await?;
        Ok(Self {
            binding,
            session,
            sshd,
            verifier,
            mesh,
            listener,
            peers: BTreeMap::new(),
            services: HashMap::new(),
            inflight: FuturesUnordered::new(),
            serial: 0,
            expires: None,
        })
    }

    /// `None` retires the current policy. Closing the source or stopping the
    /// role drains all copies and pending hellos before shutting down WG.
    pub(super) async fn serve(
        mut self,
        mut policies: mpsc::Receiver<Option<NativePolicy>>,
        stop: impl Future<Output = ()>,
    ) -> anyhow::Result<()> {
        tokio::pin!(stop);
        let result = loop {
            let expires = self.expires.clone();
            tokio::select! {
                biased;
                () = &mut stop => break Ok(()),
                policy = policies.recv() => {
                    let Some(policy) = policy else { break Ok(()) };
                    if let Err(error) = self.reconcile(policy.as_ref()).await {
                        break Err(error);
                    }
                }
                result = expired(expires) => {
                    if result.is_err() { break Err(anyhow!("cloud.receiver.clock_unavailable")); }
                    // This timer belongs to the installed topology. A newer
                    // source snapshot may already be queued, so it must not
                    // invalidate the source owner's newer publication.
                    if let Err(error) = self.reconcile(None).await { break Err(error); }
                }
                completed = self.inflight.next(), if !self.inflight.is_empty() => {
                    if let Some(id) = completed { self.services.remove(&id); }
                }
                accepted = self.listener.accept() => {
                    let Some((stream, key)) = accepted else { break Ok(()) };
                    self.accept(stream, key);
                }
            }
        };
        // Fence a concurrent policy read before dropping any service future.
        self.verifier.clear_authority();
        let all = self.peers.keys().copied().collect();
        self.drain(&all).await;
        self.mesh.shutdown().await;
        result
    }

    fn accept(&mut self, stream: WgStream, key: [u8; 32]) {
        if self.services.len() >= MAX_STREAMS || !self.peers.contains_key(&key) {
            return;
        }
        let Some(id) = self.serial.checked_add(1) else { return };
        self.serial = id;
        let (stop, cancelled) = oneshot::channel();
        self.services.insert(id, Service { peer: key, stop: Some(stop) });
        let verifier = self.verifier.clone();
        let host = self.binding.host.clone();
        let epoch = self.binding.epoch;
        let session = self.session.clone();
        let sshd = self.sshd;
        self.inflight.push(Box::pin(async move {
            let source = stream.peer_addr();
            let me = HostIdentity { host: &host, epoch, session_socket: &session, sshd };
            tokio::select! {
                biased;
                _ = cancelled => {},
                _ = serve_host_inbound(stream, key, source, &*verifier, &me) => {},
            }
            id
        }));
    }

    pub(super) async fn reconcile(&mut self, policy: Option<&NativePolicy>) -> anyhow::Result<()> {
        let mut desired = BTreeMap::new();
        let mut addresses = BTreeSet::new();
        let mut expires = None;
        if let Some(policy) = policy {
            if policy.host != self.binding.host
                || policy.epoch != self.binding.epoch
                || policy.team != self.binding.team
                || policy.peers.len() > 128
            {
                bail!("cloud.receiver.self_policy_refused");
            }
            let lifetime = policy
                .expires_at_ms
                .checked_sub(policy.checked_at_ms)
                .filter(|duration| *duration > 0 && *duration <= 30_000)
                .ok_or_else(|| anyhow!("cloud.receiver.policy_lease_refused"))?;
            let deadline = policy
                .request_started
                .checked_add(Duration::from_millis(lifetime))
                .ok_or_else(|| anyhow!("cloud.receiver.policy_lease_refused"))?;
            match self.verifier.policy_deadline(policy) {
                PolicyDeadline::Superseded => return Ok(()),
                PolicyDeadline::Closed => {}
                PolicyDeadline::Live(elapsed) if deadline > Instant::now() => {
                    expires = Some((deadline, elapsed));
                }
                PolicyDeadline::Live(_) => {}
            }
            for peer in policy.peers.iter().filter(|_| expires.is_some()) {
                let key: [u8; 32] = STANDARD
                    .decode(&peer.binding.wg_public_key)?
                    .try_into()
                    .map_err(|_| anyhow!("cloud.receiver.peer_key_refused"))?;
                let address = overlay_address(&peer.install);
                if key.iter().all(|byte| *byte == 0)
                    || desired.insert(key, address).is_some()
                    || !addresses.insert(address)
                {
                    bail!("cloud.receiver.peer_policy_refused");
                }
            }
        }
        let removed: BTreeSet<_> = self
            .peers
            .iter()
            .filter(|(key, address)| desired.get(*key) != Some(*address))
            .map(|(key, _)| *key)
            .collect();
        // Service cancellation is observable at both sockets before the
        // cryptographic peer and its source /128 are removed or replaced.
        self.drain(&removed).await;
        for key in &removed {
            self.mesh.remove_peer(*key).await?;
        }
        for (key, address) in &desired {
            if self.peers.get(key) == Some(address) {
                continue;
            }
            self.mesh
                .add_peer(WgPeer {
                    public_key: *key,
                    preshared_key: None,
                    allowed_ips: vec![IpNetwork::new(IpAddr::V6(*address), 128)?],
                    route: None,
                    persistent_keepalive: None,
                })
                .await?;
        }
        self.peers = desired;
        self.expires = expires;
        // Mesh updates may await a worker. Expiry during that work must remove
        // the installed peers before this actor can poll any service again.
        if self.expires.as_ref().is_some_and(|(active, elapsed)| {
            *active <= Instant::now()
                || elapsed.as_ref().is_some_and(|budget| budget.remaining().is_none())
        }) {
            let all = self.peers.keys().copied().collect();
            self.drain(&all).await;
            for key in all {
                self.mesh.remove_peer(key).await?;
            }
            self.peers.clear();
            self.expires = None;
        }
        Ok(())
    }

    async fn drain(&mut self, peers: &BTreeSet<[u8; 32]>) {
        let mut pending = BTreeSet::new();
        for (id, service) in &mut self.services {
            if peers.contains(&service.peer) {
                pending.insert(*id);
                if let Some(stop) = service.stop.take() {
                    let _ = stop.send(());
                }
            }
        }
        while !pending.is_empty() {
            let Some(id) = self.inflight.next().await else { break };
            self.services.remove(&id);
            pending.remove(&id);
        }
    }
}

async fn expired(deadline: Option<(Instant, Option<Deadline>)>) -> std::io::Result<()> {
    match deadline {
        Some((active, elapsed)) => super::receiver_deadline::wait(active, elapsed).await,
        None => std::future::pending().await,
    }
}

#[cfg(test)]
#[path = "native_receiver_tests.rs"]
mod tests;
