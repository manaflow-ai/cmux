//! WebRTC transport: one ordered, reliable data channel `cnx-link`
//! (webrtc-rs), ICE servers from `GET /v1/ice`, trickle ICE through
//! signaling.

use std::io;
use std::pin::Pin;
use std::sync::{Arc, Mutex, PoisonError};
use std::task::{Context, Poll};

use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::{oneshot, watch};
use webrtc::api::APIBuilder;
use webrtc::api::setting_engine::SettingEngine;
use webrtc::data::data_channel::PollDataChannel;
use webrtc::data_channel::RTCDataChannel;
use webrtc::data_channel::data_channel_init::RTCDataChannelInit;
use webrtc::ice::mdns::MulticastDnsMode;
use webrtc::ice_transport::ice_candidate::{RTCIceCandidate, RTCIceCandidateInit};
use webrtc::ice_transport::ice_candidate_type::RTCIceCandidateType;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::policy::ice_transport_policy::RTCIceTransportPolicy;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

use super::{DialError, DialFuture, Dialed, Dialer, LinkPath, SessionEvents, TransportKind};
use crate::signaling::{SessionEvent, SignalEnvelope, SignalPayload, SignalingClient};

/// The data channel label (PROTOCOL.md).
pub const LABEL: &str = "cnx-link";
/// Largest message written to the data channel; the link is a byte stream,
/// so message boundaries carry no meaning.
const MAX_MESSAGE: usize = 16 * 1024;

pub struct WebRtcDialer;

fn transport_error(error: impl std::fmt::Display) -> DialError {
    DialError::Transport(error.to_string())
}

async fn new_peer_connection(options: &super::DialOptions) -> Result<Arc<RTCPeerConnection>, DialError> {
    let mut settings = SettingEngine::default();
    settings.detach_data_channels();
    settings.set_ice_multicast_dns_mode(MulticastDnsMode::Disabled);
    if options.include_loopback {
        settings.set_include_loopback_candidate(true);
    }
    if options.exclude_cgnat {
        settings.set_ip_filter(Box::new(|ip| !super::is_cgnat(ip)));
    }
    let api = APIBuilder::new().with_setting_engine(settings).build();
    let config = RTCConfiguration {
        ice_servers: options
            .ice_servers
            .iter()
            .map(|server| RTCIceServer {
                urls: server.urls.clone(),
                username: server.username.clone().unwrap_or_default(),
                credential: server.credential.clone().unwrap_or_default(),
            })
            .collect(),
        ice_transport_policy: if options.force_relay {
            RTCIceTransportPolicy::Relay
        } else {
            RTCIceTransportPolicy::All
        },
        ..Default::default()
    };
    Ok(Arc::new(api.new_peer_connection(config).await.map_err(transport_error)?))
}

/// Trickle local candidates to `peer`.
fn trickle(pc: &RTCPeerConnection, signaling: &SignalingClient, peer: &str, session_id: &str) {
    let signaling = signaling.clone();
    let peer = peer.to_owned();
    let session_id = session_id.to_owned();
    pc.on_ice_candidate(Box::new(move |candidate: Option<RTCIceCandidate>| {
        if let Some(candidate) = candidate
            && let Ok(init) = candidate.to_json()
        {
            let _ = signaling.send_signal(
                &peer,
                &session_id,
                SignalPayload::WebrtcIce {
                    candidate: init.candidate,
                    sdp_mid: init.sdp_mid,
                    sdp_m_line_index: init.sdp_mline_index,
                },
            );
        }
        Box::pin(async {})
    }));
}

/// Remote candidates arrive before or after the remote description; hold
/// the early ones.
struct RemoteCandidates {
    exclude_cgnat: bool,
    ready: bool,
    pending: Vec<RTCIceCandidateInit>,
}

impl RemoteCandidates {
    async fn add(&mut self, pc: &RTCPeerConnection, candidate: RTCIceCandidateInit) {
        // `candidate:<foundation> <component> <proto> <priority> <address> ...`
        let address = candidate.candidate.split_whitespace().nth(4).and_then(|a| a.parse().ok());
        if self.exclude_cgnat && address.is_some_and(super::is_cgnat) {
            return;
        }
        if self.ready {
            if let Err(error) = pc.add_ice_candidate(candidate).await {
                tracing::debug!(%error, "remote candidate refused");
            }
        } else {
            self.pending.push(candidate);
        }
    }

    async fn ready(&mut self, pc: &RTCPeerConnection) {
        self.ready = true;
        for candidate in std::mem::take(&mut self.pending) {
            if let Err(error) = pc.add_ice_candidate(candidate).await {
                tracing::debug!(%error, "remote candidate refused");
            }
        }
    }
}

fn ice_init(payload: SignalPayload) -> Option<RTCIceCandidateInit> {
    match payload {
        SignalPayload::WebrtcIce { candidate, sdp_mid, sdp_m_line_index } => Some(RTCIceCandidateInit {
            candidate,
            sdp_mid,
            sdp_mline_index: sdp_m_line_index,
            username_fragment: None,
        }),
        _ => None,
    }
}

/// The data channel, once open, through `opened`.
fn on_open(channel: &Arc<RTCDataChannel>, opened: Arc<Mutex<Option<oneshot::Sender<Arc<RTCDataChannel>>>>>) {
    let handle = Arc::clone(channel);
    channel.on_open(Box::new(move || {
        if let Some(tx) = opened.lock().unwrap_or_else(PoisonError::into_inner).take() {
            let _ = tx.send(handle);
        }
        Box::pin(async {})
    }));
}

async fn selected_path(pc: &RTCPeerConnection) -> LinkPath {
    let pair = pc.sctp().transport().ice_transport().get_selected_candidate_pair().await;
    match pair {
        Some(pair)
            if pair.local.typ == RTCIceCandidateType::Relay
                || pair.remote.typ == RTCIceCandidateType::Relay =>
        {
            LinkPath::Turn
        }
        _ => LinkPath::Direct,
    }
}

/// Holds the peer connection and the post-connect signal task.
struct Guard {
    pc: Arc<RTCPeerConnection>,
    task: tokio::task::JoinHandle<()>,
    watcher: tokio::task::JoinHandle<()>,
    signaling: SignalingClient,
    session_id: String,
}

impl Drop for Guard {
    fn drop(&mut self) {
        self.task.abort();
        self.watcher.abort();
        self.signaling.unsubscribe(&self.session_id);
        let pc = Arc::clone(&self.pc);
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                let _ = pc.close().await;
            });
        }
    }
}

/// After connecting: keep adding late candidates; close on `bye`.
fn follow(
    pc: Arc<RTCPeerConnection>,
    mut events: SessionEvents,
    mut remote: RemoteCandidates,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            match events.session.recv().await {
                Some(SessionEvent::Signal(envelope)) => match envelope.payload {
                    SignalPayload::Bye { .. } => break,
                    payload => {
                        if let Some(init) = ice_init(payload) {
                            remote.add(&pc, init).await;
                        }
                    }
                },
                Some(SessionEvent::Relay(_)) => {}
                // A signaling outage does not end an established link.
                Some(SessionEvent::Disconnected) | None => return,
            }
        }
        let _ = pc.close().await;
    })
}

async fn finish(
    pc: Arc<RTCPeerConnection>,
    channel: Arc<RTCDataChannel>,
    events: SessionEvents,
    remote: RemoteCandidates,
    signaling: &SignalingClient,
    session_id: &str,
) -> Result<Dialed, DialError> {
    let raw = channel.detach().await.map_err(transport_error)?;
    let mut stream = PollDataChannel::new(raw);
    stream.set_read_buf_capacity(64 * 1024);
    let path = selected_path(&pc).await;
    let (path_tx, path_rx) = watch::channel(path);
    // The selected pair can change (ICE restart is out of scope, but a
    // nominated pair may be replaced while checks finish).
    let watcher_pc = Arc::clone(&pc);
    let task = follow(Arc::clone(&pc), events, remote);
    let watcher = tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(5));
        loop {
            interval.tick().await;
            if path_tx.is_closed() {
                return;
            }
            let path = selected_path(&watcher_pc).await;
            path_tx.send_if_modified(|current| {
                if *current == path {
                    false
                } else {
                    *current = path;
                    true
                }
            });
        }
    });
    Ok(Dialed {
        stream: Box::new(DataChannelStream { inner: stream }),
        path: path_rx,
        guard: Box::new(Guard {
            pc,
            task,
            watcher,
            signaling: signaling.clone(),
            session_id: session_id.to_owned(),
        }),
    })
}

impl Dialer for WebRtcDialer {
    fn kind(&self) -> TransportKind {
        TransportKind::WebRtc
    }

    fn dial<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        mac: &'a str,
        session_id: &'a str,
        mut events: SessionEvents,
        options: &'a super::DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let pc = new_peer_connection(options).await?;
            let init = RTCDataChannelInit { ordered: Some(true), ..Default::default() };
            let channel = pc.create_data_channel(LABEL, Some(init)).await.map_err(transport_error)?;
            let (open_tx, mut open_rx) = oneshot::channel();
            on_open(&channel, Arc::new(Mutex::new(Some(open_tx))));
            trickle(&pc, signaling, mac, session_id);
            let offer = pc.create_offer(None).await.map_err(transport_error)?;
            pc.set_local_description(offer.clone()).await.map_err(transport_error)?;
            signaling
                .send_signal(mac, session_id, SignalPayload::WebrtcOffer { sdp: offer.sdp })
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            let mut remote =
                RemoteCandidates { exclude_cgnat: options.exclude_cgnat, ready: false, pending: Vec::new() };
            let opened = loop {
                tokio::select! {
                    opened = &mut open_rx => break opened.map_err(|_| DialError::Transport("data channel never opened".into()))?,
                    event = events.next() => match event? {
                        SessionEvent::Signal(envelope) => match envelope.payload {
                            SignalPayload::WebrtcAnswer { sdp } => {
                                let answer = RTCSessionDescription::answer(sdp).map_err(transport_error)?;
                                pc.set_remote_description(answer).await.map_err(transport_error)?;
                                remote.ready(&pc).await;
                            }
                            SignalPayload::Bye { reason } => return Err(DialError::Bye(reason)),
                            payload => {
                                if let Some(init) = ice_init(payload) {
                                    remote.add(&pc, init).await;
                                }
                            }
                        },
                        SessionEvent::Relay(_) | SessionEvent::Disconnected => {}
                    },
                }
            };
            finish(pc, opened, events, remote, signaling, session_id).await
        })
    }

    fn answer<'a>(
        &'a self,
        signaling: &'a SignalingClient,
        first: SignalEnvelope,
        mut events: SessionEvents,
        options: &'a super::DialOptions,
    ) -> DialFuture<'a> {
        Box::pin(async move {
            let SignalPayload::WebrtcOffer { sdp } = first.payload else {
                return Err(DialError::Unexpected("expected webrtc-offer".into()));
            };
            let pc = new_peer_connection(options).await?;
            let (open_tx, mut open_rx) = oneshot::channel();
            let opened_slot = Arc::new(Mutex::new(Some(open_tx)));
            pc.on_data_channel(Box::new(move |channel: Arc<RTCDataChannel>| {
                if channel.label() == LABEL {
                    on_open(&channel, Arc::clone(&opened_slot));
                }
                Box::pin(async {})
            }));
            trickle(&pc, signaling, &first.from, &first.session_id);
            let offer = RTCSessionDescription::offer(sdp).map_err(transport_error)?;
            pc.set_remote_description(offer).await.map_err(transport_error)?;
            let mut remote =
                RemoteCandidates { exclude_cgnat: options.exclude_cgnat, ready: true, pending: Vec::new() };
            let answer = pc.create_answer(None).await.map_err(transport_error)?;
            pc.set_local_description(answer.clone()).await.map_err(transport_error)?;
            signaling
                .send_signal(&first.from, &first.session_id, SignalPayload::WebrtcAnswer { sdp: answer.sdp })
                .map_err(|e| DialError::Signaling(e.to_string()))?;
            let opened = loop {
                tokio::select! {
                    opened = &mut open_rx => break opened.map_err(|_| DialError::Transport("data channel never opened".into()))?,
                    event = events.next() => match event? {
                        SessionEvent::Signal(envelope) => match envelope.payload {
                            SignalPayload::Bye { reason } => return Err(DialError::Bye(reason)),
                            payload => {
                                if let Some(init) = ice_init(payload) {
                                    remote.add(&pc, init).await;
                                }
                            }
                        },
                        SessionEvent::Relay(_) | SessionEvent::Disconnected => {}
                    },
                }
            };
            finish(pc, opened, events, remote, signaling, &first.session_id).await
        })
    }
}

/// The detached data channel as a byte stream with bounded message size.
struct DataChannelStream {
    inner: PollDataChannel,
}

impl AsyncRead for DataChannelStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for DataChannelStream {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        let len = buf.len().min(MAX_MESSAGE);
        Pin::new(&mut self.inner).poll_write(cx, &buf[..len])
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}
