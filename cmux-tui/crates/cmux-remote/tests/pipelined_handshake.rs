//! `initiate_secure_link_pipelined`: the client's first record goes out before the daemon's
//! welcome, and the first receive still reads and checks that welcome, so a refusal fails the
//! link before any answer is handed back.

use std::collections::BTreeMap;
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::crypto::{
    AuthGrant, AuthRequest, ClientAuthMode, ClientHandshake, ConnectionAttemptId, CryptoError,
    InboundAuthEvidence, NetworkPeer, ServerAuthenticator, ServiceAuthority, StaticIdentity,
    accept_secure_link, initiate_secure_link_pipelined,
};
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote_protocol::{Lane, SessionId};
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
        "channel link"
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

struct Authenticator {
    accept: bool,
}

#[async_trait]
impl ServerAuthenticator for Authenticator {
    async fn invitation_secret(&self, _id: &str) -> Result<Option<[u8; 32]>, CryptoError> {
        Ok(None)
    }

    async fn authorize(&self, _request: AuthRequest) -> Result<AuthGrant, String> {
        // Slow on purpose: the client's record must already be on its way.
        tokio::time::sleep(Duration::from_millis(50)).await;
        if self.accept {
            Ok(AuthGrant {
                device_id: "device".into(),
                daemon_name: "daemon".into(),
                revocation_generation: 0,
                authority: ServiceAuthority::default(),
            })
        } else {
            Err("not enrolled".into())
        }
    }
}

fn handshake(client: &StaticIdentity, daemon: &StaticIdentity) -> ClientHandshake {
    ClientHandshake {
        identity: client.clone(),
        expected_daemon: Some(daemon.public_key()),
        auth: ClientAuthMode::Enrolled,
        device_name: "client".into(),
        session: SessionId([7; 16]),
        lane: Lane::Control,
        lanes: vec![Lane::Control],
        generation: 0,
        connection_attempt: ConnectionAttemptId([3; 16]),
        resume: BTreeMap::new(),
        daemon_takes_ik: false,
        handshake_timeout: Duration::from_secs(5),
    }
}

#[tokio::test]
async fn the_first_record_goes_before_the_welcome_and_the_answer_comes_after_it() {
    let client = StaticIdentity::generate().unwrap();
    let daemon = StaticIdentity::generate().unwrap();
    let (near, far) = pair();
    let server = tokio::spawn({
        let daemon = daemon.clone();
        async move {
            let accepted = accept_secure_link(
                Box::new(far),
                &daemon,
                &Authenticator { accept: true },
                InboundAuthEvidence::Network(NetworkPeer::Relay),
            )
            .await
            .unwrap();
            let hello = accepted.link.receive().await.unwrap().unwrap();
            assert_eq!(&hello[..], b"hello");
            accepted.link.send(Bytes::from_static(b"answer")).await.unwrap();
            accepted
        }
    });
    let secure =
        initiate_secure_link_pipelined(Box::new(near), handshake(&client, &daemon)).await.unwrap();
    secure.send(Bytes::from_static(b"hello")).await.unwrap();
    let answer = secure.receive().await.unwrap().unwrap();
    assert_eq!(&answer[..], b"answer");
    let _accepted = server.await.unwrap();
}

#[tokio::test]
async fn a_refused_welcome_fails_the_first_receive() {
    let client = StaticIdentity::generate().unwrap();
    let daemon = StaticIdentity::generate().unwrap();
    let (near, far) = pair();
    let server = tokio::spawn({
        let daemon = daemon.clone();
        async move {
            let refused = accept_secure_link(
                Box::new(far),
                &daemon,
                &Authenticator { accept: false },
                InboundAuthEvidence::Network(NetworkPeer::Relay),
            )
            .await;
            assert!(matches!(refused, Err(CryptoError::Unauthorized(_))));
        }
    });
    let secure =
        initiate_secure_link_pipelined(Box::new(near), handshake(&client, &daemon)).await.unwrap();
    secure.send(Bytes::from_static(b"hello")).await.unwrap();
    let refused = secure.receive().await.expect_err("a refused welcome handed back a record");
    assert!(refused.to_string().contains("not enrolled"), "{refused}");
    server.await.unwrap();
}

#[tokio::test]
async fn a_pipelined_handshake_needs_a_pinned_daemon_key() {
    let client = StaticIdentity::generate().unwrap();
    let daemon = StaticIdentity::generate().unwrap();
    let (near, _far) = pair();
    let mut config = handshake(&client, &daemon);
    config.expected_daemon = None;
    assert!(initiate_secure_link_pipelined(Box::new(near), config).await.is_err());
}
