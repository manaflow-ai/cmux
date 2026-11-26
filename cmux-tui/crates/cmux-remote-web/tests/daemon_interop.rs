//! The browser client against the daemon's own handshake (`cmux_remote::crypto::accept_secure_link`),
//! not a hand-written peer: the prelude, the Noise XX messages, the hello, the welcome and the
//! encrypted records must be what the native daemon reads and writes.
#![cfg(not(target_arch = "wasm32"))]

use std::sync::{Arc, Mutex as StdMutex};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::crypto::{
    AuthGrant, AuthKind, AuthRequest, CryptoError, InboundAuthEvidence, NetworkPeer,
    ServerAuthenticator, ServiceAuthority, StaticIdentity, accept_secure_link,
};
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote_protocol::{
    FrameFlags, Lane, Service, ServiceControl, SessionId, WireFrame,
};
use cmux_remote_web::{ClientState, RemoteWebClient, RemoteWebConfig};
use tokio::sync::{Mutex, mpsc};

struct ChannelLink {
    out: mpsc::UnboundedSender<Bytes>,
    inc: Mutex<mpsc::UnboundedReceiver<Bytes>>,
}

fn pair() -> (ChannelLink, ChannelLink) {
    let (a_out, b_in) = mpsc::unbounded_channel();
    let (b_out, a_in) = mpsc::unbounded_channel();
    (
        ChannelLink { out: a_out, inc: Mutex::new(a_in) },
        ChannelLink { out: b_out, inc: Mutex::new(b_in) },
    )
}

#[async_trait]
impl FrameLink for ChannelLink {
    fn description(&self) -> &str {
        "browser channel"
    }

    fn maximum_frame_bytes(&self) -> usize {
        65_535
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        self.out.send(frame).map_err(|_| LinkError::Closed)
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        Ok(self.inc.lock().await.recv().await)
    }

    async fn close(&self) -> Result<(), LinkError> {
        self.inc.lock().await.close();
        Ok(())
    }
}

#[derive(Default)]
struct Authenticator {
    refuse: Option<&'static str>,
    seen: StdMutex<Vec<AuthRequest>>,
}

#[async_trait]
impl ServerAuthenticator for Authenticator {
    async fn invitation_secret(&self, _id: &str) -> Result<Option<[u8; 32]>, CryptoError> {
        Ok(None)
    }

    async fn authorize(&self, request: AuthRequest) -> Result<AuthGrant, String> {
        self.seen.lock().unwrap().push(request);
        match self.refuse {
            Some(reason) => Err(reason.into()),
            None => Ok(AuthGrant {
                device_id: "browser-device".into(),
                daemon_name: "daemon".into(),
                revocation_generation: 0,
                authority: ServiceAuthority::default(),
            }),
        }
    }
}

const SESSION: SessionId = SessionId([5; 16]);

fn browser(key: [u8; 32]) -> RemoteWebClient {
    let mut config = RemoteWebConfig::new(key, SESSION, "browser-tab");
    config.resume.insert(Lane::Interactive, 4);
    RemoteWebClient::from_config(config).unwrap()
}

async fn flush(client: &mut RemoteWebClient, link: &ChannelLink) {
    while let Some(message) = client.next_outbound() {
        link.send(Bytes::from(message)).await.unwrap();
    }
}

async fn feed(client: &mut RemoteWebClient, link: &ChannelLink) -> Result<(), String> {
    let message = link.receive().await.unwrap().expect("daemon sent a message");
    client.receive(&message).map_err(|error| error.to_string())
}

/// Prelude and msg1 out, msg2 in, msg3 (the hello) out, the welcome in.
async fn handshake(client: &mut RemoteWebClient, link: &ChannelLink) -> Result<(), String> {
    client.start().unwrap();
    flush(client, link).await;
    feed(client, link).await?;
    flush(client, link).await;
    feed(client, link).await
}

#[tokio::test]
async fn the_daemon_accepts_the_browser_and_acpmux_frames_cross_both_ways() {
    let daemon = StaticIdentity::generate().unwrap();
    let browser_key = StaticIdentity::generate().unwrap();
    let authenticator = Arc::new(Authenticator::default());
    let (near, far) = pair();
    let server = tokio::spawn({
        let daemon = daemon.clone();
        let authenticator = authenticator.clone();
        async move {
            let accepted = accept_secure_link(
                Box::new(far),
                &daemon,
                &*authenticator,
                InboundAuthEvidence::Network(NetworkPeer::Relay),
            )
            .await
            .expect("daemon accepts the browser");
            assert_eq!(accepted.session, SESSION);
            assert_eq!(accepted.resume.get(&Lane::Interactive), Some(&4));

            let open = WireFrame::decode(&accepted.link.receive().await.unwrap().unwrap()).unwrap();
            assert_eq!(open.lane, Lane::Tunnel);
            assert!(open.flags.contains(FrameFlags::OPEN));
            let control: ServiceControl = serde_json::from_slice(&open.payload).unwrap();
            assert!(matches!(control, ServiceControl::Open { service: Service::Acpmux, .. }));

            let request = WireFrame::decode(&accepted.link.receive().await.unwrap().unwrap()).unwrap();
            assert_eq!(request.stream, open.stream);
            assert_eq!(&request.payload[..], br#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#);

            let answer = WireFrame {
                session: SESSION,
                generation: 0,
                lane: Lane::Tunnel,
                flags: FrameFlags::RELIABLE,
                sequence: 0,
                acknowledgement: request.sequence,
                stream: open.stream,
                payload: br#"{"jsonrpc":"2.0","id":1,"result":{}}"#.to_vec(),
            };
            accepted.link.send(Bytes::from(answer.encode().unwrap())).await.unwrap();
            accepted
        }
    });

    let mut client = browser(*browser_key.private_key());
    handshake(&mut client, &near).await.expect("browser completes the daemon's handshake");
    assert_eq!(client.state(), ClientState::Established);

    client.open_acpmux().unwrap();
    client.send_acpmux(br#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#).unwrap();
    flush(&mut client, &near).await;
    feed(&mut client, &near).await.unwrap();
    assert_eq!(
        client.next_event().as_deref(),
        Some(&br#"{"jsonrpc":"2.0","id":1,"result":{}}"#[..])
    );

    let accepted = server.await.unwrap();
    assert_eq!(accepted.link.remote_static(), browser_key.public_key());
    let seen = authenticator.seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].mode, AuthKind::Enrolled);
    assert_eq!(seen[0].device_name, "browser-tab");
    assert_eq!(seen[0].device_public_key, browser_key.public_key());
}

#[tokio::test]
async fn a_refused_browser_hears_the_daemons_reason() {
    let daemon = StaticIdentity::generate().unwrap();
    let browser_key = StaticIdentity::generate().unwrap();
    let authenticator = Arc::new(Authenticator { refuse: Some("device revoked"), ..Default::default() });
    let (near, far) = pair();
    let server = tokio::spawn({
        let authenticator = authenticator.clone();
        async move {
            accept_secure_link(
                Box::new(far),
                &daemon,
                &*authenticator,
                InboundAuthEvidence::Network(NetworkPeer::Relay),
            )
            .await
        }
    });

    let mut client = browser(*browser_key.private_key());
    let error = handshake(&mut client, &near).await.expect_err("a refused browser fails");
    assert!(error.contains("device revoked"), "{error}");
    assert!(matches!(server.await.unwrap(), Err(CryptoError::Unauthorized(_))));
}
