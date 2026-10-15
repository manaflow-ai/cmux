//! Roaming: a WireGuard session that outlives network changes
//! (PROTOCOL.md "WireGuard roaming").
//!
//! When a side's network changes (Wi-Fi to cellular, another Wi-Fi, a new
//! address, back from airplane mode) [`network_changed`] moves every live
//! session onto a fresh UDP socket and at once sends an authenticated
//! datagram from it (a keepalive on a fresh session, else a handshake
//! initiation), so the peer roams to the new address (WireGuard's own
//! endpoint roaming). While the route settles every datagram also goes
//! through the backend relay and to all of the peer's candidates. In the
//! background the side learns its new reflexive address (STUN on the new
//! socket), the phone takes a fresh TURN allocation (the old one belongs to
//! the old network), and the new endpoints go to the peer inside the tunnel
//! as overlay UDP datagrams on port [`ROAM_PORT`], resent until
//! acknowledged. The peer then sprays its own datagrams at them, which opens
//! its side of a NAT that filters by address. Keys, the session and every
//! TCP stream stay: nothing is dialed again.
//!
//! A network change usually kills the signaling WebSocket too; [`rehome`]
//! moves the sessions of a device onto its new socket, so relay frames and
//! `bye` travel again.

use std::sync::Weak;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_wg::{Priority, WgDatagramSocket};
use serde::{Deserialize, Serialize};

use super::*;

/// Overlay UDP port of the roaming messages, next to the link's 7420.
pub const ROAM_PORT: u16 = 7421;
/// Waits before each resend of an endpoint announcement that the peer has
/// not acknowledged.
const ANNOUNCE_RESENDS: [Duration; 5] = [
    Duration::from_millis(150),
    Duration::from_millis(400),
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
];
/// The most endpoints one announcement may carry.
const MAX_ENDPOINTS: usize = 16;

/// Changes the roaming side makes to its [`HybridUnderlay`].
pub(super) enum Control {
    /// This side's network changed: carry the session on `socket`, ask
    /// `stun` for the socket's reflexive address and send what they answer
    /// to `reflexive`. The old TURN allocation is released.
    Rebind {
        socket: UdpSocket,
        stun: Vec<SocketAddr>,
        reflexive: mpsc::UnboundedSender<SocketAddr>,
        timeline: Timeline,
    },
    /// A TURN allocation on the new network.
    Turn(TurnCarrier),
    /// The peer announced new endpoints.
    PeerEndpoints {
        endpoints: Vec<String>,
        /// Which of them are the peer's TURN relayed addresses.
        relayed: Vec<String>,
    },
    /// The session moved to a new signaling socket.
    Rehomed,
    /// Debug and tests: the socket's network is gone.
    Blackhole,
}

/// Relayed addresses one announcement carries (a phone has one TURN
/// allocation), so the message stays within one tunnel datagram.
const MAX_RELAYED: usize = 2;

/// This side's endpoints to announce, and which of them are its TURN
/// relayed addresses.
type Announcement = (Vec<String>, Vec<String>);

/// The roaming messages (JSON in one overlay UDP datagram).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "kebab-case")]
enum RoamMessage {
    /// This side's endpoints now; `gen` grows with every announcement.
    Endpoints {
        generation: u64,
        endpoints: Vec<String>,
        /// Which of `endpoints` are this side's TURN relayed addresses (the
        /// phone's new allocation), so the Mac keeps labeling a UDP route to
        /// one as TURN after a roam; absent from older peers.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        relayed: Vec<String>,
    },
    Ack {
        generation: u64,
    },
}

pub(super) struct SessionParts {
    pub session_id: String,
    pub peer: String,
    pub dialer: bool,
    pub peer_ip: Ipv4Addr,
    pub signaling: Arc<Mutex<SignalingClient>>,
    pub net: Arc<Mutex<Option<Arc<WgNet>>>>,
    pub control: mpsc::UnboundedSender<Control>,
    pub relay_in: mpsc::UnboundedSender<Bytes>,
    pub options: DialOptions,
    pub stun: Vec<SocketAddr>,
    pub endpoints: Vec<String>,
}

/// One live tunnel, as roaming sees it.
pub(super) struct Session {
    session_id: String,
    peer: String,
    dialer: bool,
    peer_ip: Ipv4Addr,
    signaling: Arc<Mutex<SignalingClient>>,
    net: Arc<Mutex<Option<Arc<WgNet>>>>,
    control: mpsc::UnboundedSender<Control>,
    relay_in: mpsc::UnboundedSender<Bytes>,
    options: DialOptions,
    stun: Mutex<Vec<SocketAddr>>,
    /// This side's endpoints as last offered to the peer.
    endpoints: Mutex<Vec<String>>,
    follow: Mutex<Option<JoinHandle<()>>>,
    announce: Mutex<Option<mpsc::UnboundedSender<Announcement>>>,
    control_task: Mutex<Option<JoinHandle<()>>>,
    roaming: tokio::sync::Mutex<()>,
    last_roam: Mutex<Option<Timeline>>,
    /// Counts network changes on either side (the media lane asks for a
    /// keyframe after each).
    path_epoch: Arc<watch::Sender<u64>>,
    closed: AtomicBool,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn registry() -> &'static Mutex<Vec<Weak<Session>>> {
    static SESSIONS: Mutex<Vec<Weak<Session>>> = Mutex::new(Vec::new());
    &SESSIONS
}

/// Every live session of this process.
fn live() -> Vec<Arc<Session>> {
    let mut sessions = lock(registry());
    sessions.retain(|weak| weak.strong_count() > 0);
    sessions.iter().filter_map(Weak::upgrade).filter(|s| !s.closed.load(Ordering::Relaxed)).collect()
}

fn find(session_id: &str, dialer: bool) -> Option<Arc<Session>> {
    live().into_iter().find(|s| s.session_id == session_id && s.dialer == dialer)
}

impl Session {
    pub(super) fn register(parts: SessionParts) -> Arc<Self> {
        let session = Arc::new(Self {
            session_id: parts.session_id,
            peer: parts.peer,
            dialer: parts.dialer,
            peer_ip: parts.peer_ip,
            signaling: parts.signaling,
            net: parts.net,
            control: parts.control,
            relay_in: parts.relay_in,
            options: parts.options,
            stun: Mutex::new(parts.stun),
            endpoints: Mutex::new(parts.endpoints),
            follow: Mutex::new(None),
            announce: Mutex::new(None),
            control_task: Mutex::new(None),
            roaming: tokio::sync::Mutex::new(()),
            last_roam: Mutex::new(None),
            path_epoch: Arc::new(watch::channel(0).0),
            closed: AtomicBool::new(false),
        });
        lock(registry()).push(Arc::downgrade(&session));
        session
    }

    /// Counts this session's network changes: its own roams and the peer's
    /// endpoint announcements.
    pub(super) fn path_changes(&self) -> watch::Receiver<u64> {
        self.path_epoch.subscribe()
    }

    pub(super) fn net(&self) -> Result<Arc<WgNet>, DialError> {
        running(&self.net)
    }

    fn signaling(&self) -> SignalingClient {
        lock(&self.signaling).clone()
    }

    /// Feed one relay frame's datagram to the tunnel.
    pub(super) fn relay(&self, datagram: Bytes) {
        let _ = self.relay_in.send(datagram);
    }

    /// Feed `events` (relay frames, `bye`) to the tunnel, replacing the
    /// subscription of an earlier signaling socket.
    pub(super) fn follow(&self, mut events: mpsc::UnboundedReceiver<SessionEvent>) {
        let relay_in = self.relay_in.clone();
        let net = Arc::clone(&self.net);
        let task = tokio::spawn(async move {
            loop {
                match events.recv().await {
                    Some(SessionEvent::Relay(datagram)) => {
                        let _ = relay_in.send(datagram);
                    }
                    Some(SessionEvent::Signal(envelope)) => {
                        if matches!(envelope.payload, SignalPayload::Bye { .. }) {
                            lock(&net).take();
                            return;
                        }
                    }
                    // Direct UDP outlives a signaling outage; `rehome`
                    // follows the next socket.
                    Some(SessionEvent::Disconnected) | None => return,
                }
            }
        });
        if let Some(old) = lock(&self.follow).replace(task) {
            old.abort();
        }
    }

    /// Listen for the peer's endpoint announcements and send ours.
    pub(super) async fn start_control(&self, net: &WgNet) {
        let socket = match net.bind_datagram(ROAM_PORT).await {
            Ok(socket) => socket,
            Err(error) => {
                tracing::debug!(%error, "no roaming port; this session cannot announce endpoints");
                return;
            }
        };
        let (announce_tx, announce_rx) = mpsc::unbounded_channel();
        let peer = SocketAddr::new(IpAddr::V4(self.peer_ip), ROAM_PORT);
        let task = tokio::spawn(run_control(
            socket,
            peer,
            self.control.clone(),
            Arc::clone(&self.net),
            announce_rx,
            Arc::clone(&self.path_epoch),
        ));
        *lock(&self.announce) = Some(announce_tx);
        if let Some(old) = lock(&self.control_task).replace(task) {
            old.abort();
        }
    }

    /// End the session: stop its tasks and tell the peer.
    pub(super) fn close(&self) {
        self.closed.store(true, Ordering::Relaxed);
        if let Some(task) = lock(&self.follow).take() {
            task.abort();
        }
        if let Some(task) = lock(&self.control_task).take() {
            task.abort();
        }
        let signaling = self.signaling();
        // Tell the peer, so its tunnel stops sending relay frames the
        // backend can only answer with `offline` or `not_owner`.
        if lock(&self.net).take().is_some() {
            let _ = signaling.send_signal(
                &self.peer,
                &self.session_id,
                SignalPayload::Bye { reason: "closed".into() },
            );
        }
        signaling.unsubscribe(&self.session_id);
    }

    /// Tell the peer this side's endpoints (an empty list: unchanged, but
    /// the network changed, so the peer resends what it sent lately).
    /// `relayed`: which of `endpoints` are this side's TURN relayed addresses.
    fn announce(&self, endpoints: Vec<String>, relayed: Vec<String>) {
        if !endpoints.is_empty() {
            lock(&self.endpoints).clone_from(&endpoints);
        }
        if let Some(tx) = lock(&self.announce).as_ref() {
            let _ = tx.send((endpoints, relayed));
        }
    }

    async fn stun_servers(&self) -> Vec<SocketAddr> {
        let cached = lock(&self.stun).clone();
        if !cached.is_empty() || self.options.relay_only {
            return cached;
        }
        let resolved = resolve_stun(&self.options).await;
        lock(&self.stun).clone_from(&resolved);
        resolved
    }

    /// Move the session onto the network the device has now.
    async fn roam(&self) -> Timeline {
        let _one_at_a_time = self.roaming.lock().await;
        let timeline = Timeline::new();
        timeline.mark("network_changed");
        *lock(&self.last_roam) = Some(timeline.clone());
        let Ok(net) = self.net() else { return timeline };
        let socket = match UdpSocket::bind("0.0.0.0:0").await {
            Ok(socket) => socket,
            Err(error) => {
                // No network yet (airplane mode): the next change roams.
                tracing::debug!(%error, "no socket for the roam");
                return timeline;
            }
        };
        let port = socket.local_addr().map(|addr| addr.port()).unwrap_or_default();
        let stun = self.stun_servers().await;
        let asked = stun.len();
        let (reflexive_tx, mut reflexive_rx) = mpsc::unbounded_channel();
        let rebind = Control::Rebind { socket, stun, reflexive: reflexive_tx, timeline: timeline.clone() };
        if self.control.send(rebind).is_err() {
            return timeline;
        }
        // The underlay applies the rebind before it sends this.
        if net.refresh().await.is_err() {
            return timeline;
        }
        timeline.mark("roam_reasserted");
        self.path_epoch.send_modify(|epoch| *epoch += 1);
        let mut endpoints = host_endpoints(port, &self.options);
        self.announce(offered(endpoints.iter().copied(), &self.options), Vec::new());
        let turn =
            async { if self.dialer { TurnCarrier::allocate(&self.options.ice_servers).await } else { None } };
        let reflexive = async {
            let deadline = Instant::now() + STUN_WAIT;
            let mut found = Vec::new();
            while found.len() < asked {
                match tokio::time::timeout_at(deadline, reflexive_rx.recv()).await {
                    Ok(Some(address)) => found.push(address),
                    _ => break,
                }
            }
            found
        };
        let (turn, reflexive) = tokio::join!(turn, reflexive);
        let known = endpoints.len();
        for address in reflexive {
            if !endpoints.contains(&address) {
                endpoints.push(address);
            }
        }
        let mut relayed = Vec::new();
        if let Some(turn) = turn {
            timeline.mark("roam_turn_allocated");
            endpoints.push(turn.relayed);
            relayed.push(turn.relayed.to_string());
            let _ = self.control.send(Control::Turn(turn));
            let _ = net.refresh().await;
        }
        if endpoints.len() != known {
            self.announce(offered(endpoints, &self.options), relayed);
        }
        timeline.mark("roam_gathered");
        tracing::info!(session = self.session_id, timings = %timeline.summary(), "WireGuard roamed");
        timeline
    }

    fn rehome_onto(&self, client: &SignalingClient) {
        let old = std::mem::replace(&mut *lock(&self.signaling), client.clone());
        old.unsubscribe(&self.session_id);
        self.follow(client.subscribe(&self.session_id));
        let _ = self.control.send(Control::Rehomed);
        // Relay frames toward this side's old socket were lost: the peer
        // resends what it sent lately.
        self.announce(Vec::new(), Vec::new());
        tracing::debug!(session = self.session_id, "WireGuard session moved to a new signaling socket");
    }
}

async fn send_message(socket: &WgDatagramSocket, peer: SocketAddr, message: &RoamMessage) {
    let bytes = serde_json::to_vec(message).expect("roam message serializes");
    if let Err(error) = socket.send_to(&bytes, peer, Priority::Interactive).await {
        tracing::debug!(%error, "roam message not sent");
    }
}

/// The roaming messages of one session: announce this side's endpoints
/// until the peer acknowledges them, and apply the peer's.
async fn run_control(
    mut socket: WgDatagramSocket,
    peer: SocketAddr,
    control: mpsc::UnboundedSender<Control>,
    net: Arc<Mutex<Option<Arc<WgNet>>>>,
    mut announce: mpsc::UnboundedReceiver<Announcement>,
    path_epoch: Arc<watch::Sender<u64>>,
) {
    let mut generation = 0u64;
    let mut pending: Option<RoamMessage> = None;
    let mut resends = 0usize;
    let mut resend_at: Option<Instant> = None;
    let mut applied = 0u64;
    // The first endpoint the peer last announced (its new socket's host
    // address, or its TURN address when relay only). A new one is a network
    // change for the media lane; the same one again is not: a roam announces
    // twice (host endpoints at once, then with the reflexive ones), and an
    // empty list follows a mere signaling-socket move.
    let mut peer_first: Option<String> = None;
    loop {
        let resend = async {
            match resend_at {
                Some(at) => tokio::time::sleep_until(at).await,
                None => std::future::pending().await,
            }
        };
        tokio::select! {
            endpoints = announce.recv() => {
                let Some((mut endpoints, relayed)) = endpoints else { return };
                endpoints.truncate(MAX_ENDPOINTS);
                generation += 1;
                let relayed = relayed.into_iter().filter(|text| endpoints.contains(text)).take(MAX_RELAYED).collect();
                let message = RoamMessage::Endpoints { generation, endpoints, relayed };
                send_message(&socket, peer, &message).await;
                pending = Some(message);
                resends = 0;
                resend_at = Some(Instant::now() + ANNOUNCE_RESENDS[0]);
            }
            () = resend => {
                if let Some(message) = &pending {
                    send_message(&socket, peer, message).await;
                }
                resends += 1;
                resend_at = ANNOUNCE_RESENDS.get(resends).map(|wait| Instant::now() + *wait);
                if resend_at.is_none() {
                    pending = None;
                }
            }
            received = socket.recv_from() => {
                let Some((payload, from)) = received else { return };
                if from.ip() != peer.ip() {
                    continue;
                }
                match serde_json::from_slice::<RoamMessage>(&payload) {
                    Ok(RoamMessage::Endpoints { generation: theirs, endpoints, relayed }) => {
                        send_message(&socket, peer, &RoamMessage::Ack { generation: theirs }).await;
                        if theirs <= applied {
                            continue;
                        }
                        applied = theirs;
                        let endpoints: Vec<String> = endpoints
                            .into_iter()
                            .filter(|text| text.parse::<SocketAddr>().is_ok())
                            .take(MAX_ENDPOINTS)
                            .collect();
                        let moved = endpoints.first().is_some_and(|first| peer_first.as_ref() != Some(first));
                        if moved {
                            peer_first = endpoints.first().cloned();
                        }
                        let relayed = relayed.into_iter().filter(|text| endpoints.contains(text)).take(MAX_RELAYED).collect();
                        if control.send(Control::PeerEndpoints { endpoints, relayed }).is_err() {
                            return;
                        }
                        if moved {
                            // The peer's network changed.
                            path_epoch.send_modify(|epoch| *epoch += 1);
                        }
                        // Send at once, so the spray opens this side's NAT
                        // toward the peer's new address.
                        let current = lock(&net).clone();
                        if let Some(net) = current {
                            let _ = net.refresh().await;
                        }
                    }
                    Ok(RoamMessage::Ack { generation: acked }) => {
                        if matches!(&pending, Some(RoamMessage::Endpoints { generation, .. }) if *generation <= acked) {
                            pending = None;
                            resend_at = None;
                        }
                    }
                    Err(error) => tracing::debug!(%error, "unreadable roam message"),
                }
            }
        }
    }
}

/// The device's network changed (or came back): move every live WireGuard
/// session onto it. Returns each session's roam marks (`network_changed`,
/// `roam_reasserted`, `roam_first_packet`, `roam_direct` or `roam_turn`,
/// `roam_turn_allocated`, `roam_gathered`), which keep filling in after
/// this returns.
pub async fn network_changed() -> Vec<(String, Timeline)> {
    let sessions = live();
    let roams =
        sessions.iter().map(|session| async move { (session.session_id.clone(), session.roam().await) });
    futures_util::future::join_all(roams).await
}

/// Move the sessions on `client`'s device that run on another (dead or
/// replaced) signaling socket onto `client`. Returns how many moved.
pub fn rehome(client: &SignalingClient) -> usize {
    let mut moved = 0;
    for session in live() {
        let current = session.signaling();
        if current.device_id() == client.device_id() && !current.same_socket(client) {
            session.rehome_onto(client);
            moved += 1;
        }
    }
    moved
}

/// The marks of session `session_id`'s latest roam.
pub fn roam_timeline(session_id: &str) -> Option<Timeline> {
    live().into_iter().find(|s| s.session_id == session_id).and_then(|s| lock(&s.last_roam).clone())
}

/// Test support: roam one side of one session (both sides of a test run in
/// one process).
#[doc(hidden)]
pub async fn roam_session(session_id: &str, dialer: bool) -> Option<Timeline> {
    let session = find(session_id, dialer)?;
    Some(session.roam().await)
}

/// Debug and tests: the current network of one side of `session_id` (or of
/// every session when `None`) goes away without a roam: nothing its socket
/// or TURN allocation sends arrives, and nothing reaches it. Returns how
/// many sessions it hit.
#[doc(hidden)]
pub fn simulate_network_loss(session_id: Option<&str>, dialer: bool) -> usize {
    let mut hit = 0;
    for session in live() {
        if session.dialer == dialer && session_id.is_none_or(|id| id == session.session_id) {
            let _ = session.control.send(Control::Blackhole);
            hit += 1;
        }
    }
    hit
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roam_messages_are_small_json() {
        let message = RoamMessage::Endpoints {
            generation: 3,
            endpoints: vec!["203.0.113.7:40000".into()],
            relayed: Vec::new(),
        };
        let text = serde_json::to_string(&message).unwrap();
        assert_eq!(text, r#"{"t":"endpoints","generation":3,"endpoints":["203.0.113.7:40000"]}"#);
        assert_eq!(serde_json::from_str::<RoamMessage>(&text).unwrap(), message);
        let many = RoamMessage::Endpoints {
            generation: u64::MAX,
            endpoints: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_ENDPOINTS],
            relayed: vec!["[2001:db8::1234:5678:9abc:def0]:65535".into(); MAX_RELAYED],
        };
        // Fits one datagram of the 1280-byte tunnel.
        assert!(serde_json::to_vec(&many).unwrap().len() <= 1232);
        assert_eq!(
            serde_json::to_string(&RoamMessage::Ack { generation: 9 }).unwrap(),
            r#"{"t":"ack","generation":9}"#
        );
    }
}
