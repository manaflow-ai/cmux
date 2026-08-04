//! The iroh listener: accepts admitted connections and bridges each
//! subsequent bidirectional stream to the local cmux-tui session socket as an
//! ordinary protocol v10 JSON-lines client.
//!
//! Admission contract (stage-1 subset of the transport architecture's
//! barrier): the first bidirectional stream on a connection must carry one
//! bounded JSON line `{"v":1,"grant":"<compact JWS>"}` within 5 seconds. The
//! grant must verify against the broker-distributed keys and name this exact
//! acceptor and the TLS-authenticated initiator. Anything else closes the
//! connection. No session stream is bridged before admission succeeds, and
//! the connection closes at grant expiry unless revalidation extends it.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::Context;
use iroh::endpoint::Connection;
use iroh::protocol::{AcceptError, Router};
use tokio::io::{AsyncBufReadExt, AsyncReadExt as _, AsyncWriteExt, BufReader};
use tokio::sync::Semaphore;

use crate::broker::{BrokerClient, BrokerConfig};
use crate::endpoint::{bind_endpoint, fresh_relay_token, log_id, spawn_relay_maintenance};
use crate::grant::{self, AcceptorIdentity, VerificationKeySet};
use crate::identity::{
    Identity, load_broker_cache, load_credential, load_or_mint_identity, save_broker_cache,
    save_identity, state_root,
};
use crate::timefmt::unix_seconds_now;

const ADMISSION_DEADLINE: Duration = Duration::from_secs(5);
const ADMISSION_MAX_BYTES: usize = 16 * 1024;
const MAX_UNADMITTED_CONNECTIONS: usize = 16;
const MAX_ADMITTED_CONNECTIONS: usize = 64;
const REVALIDATION_INTERVAL: Duration = Duration::from_secs(30);

pub struct ListenArgs {
    pub state: Option<PathBuf>,
    pub session: String,
    pub socket: Option<PathBuf>,
    pub broker: Option<String>,
    pub tag: Option<String>,
}

struct AdmittedPeer {
    connection: Connection,
    initiator_endpoint_id: String,
    grant_exp_unix: i64,
}

#[derive(Clone)]
struct ListenerShared {
    identity: Arc<Identity>,
    endpoint_id_hex: Arc<String>,
    socket_path: Arc<PathBuf>,
    keys: Arc<Mutex<VerificationKeySet>>,
    admitted: Arc<Mutex<HashMap<usize, AdmittedPeer>>>,
    unadmitted_permits: Arc<Semaphore>,
}

pub async fn run(args: ListenArgs) -> anyhow::Result<()> {
    let root = state_root(args.state.as_deref())?;
    let mut identity = load_or_mint_identity(&root, args.tag.as_deref())?;
    let credential = load_credential(&root)?.context(
        "no device credential; run `cmux-tui-iroh enroll --token <enrollment-token>` first",
    )?;
    let config = BrokerConfig::resolve(args.broker.as_deref())?;
    let broker = Arc::new(BrokerClient::new(config, credential, root.clone())?);
    let socket_path = args.socket.clone().unwrap_or_else(|| default_session_socket(&args.session));

    // Register (heartbeat) this device's slot and refresh the verification keys.
    let registration = broker.register(&identity, true).await?;
    if identity.binding_id.as_deref() != Some(registration.binding_id.as_str()) {
        identity.binding_id = Some(registration.binding_id.clone());
        save_identity(&root, &identity)?;
    }
    let discovery = match registration.discovery {
        Some(discovery) => discovery,
        None => broker.discover().await?,
    };
    let keys = VerificationKeySet::from_value(&discovery.grant_verification_keys)?;
    let mut cache = load_broker_cache(&root)?;
    cache.grant_verification_keys = Some(discovery.grant_verification_keys.clone());
    save_broker_cache(&root, &cache)?;

    // Relay credential: prefer the register bootstrap, else mint/reuse.
    let relay_token = match registration.relay_token {
        Some(token) => {
            let mut cache = load_broker_cache(&root)?;
            cache.relay_token = Some(token.token.clone());
            cache.relay_token_expires_at = Some(token.expires_at_unix);
            save_broker_cache(&root, &cache)?;
            token
        }
        None => fresh_relay_token(&broker, &identity, &root).await?,
    };

    let endpoint = bind_endpoint(&identity, &relay_token, true).await?;
    endpoint.online().await;
    let endpoint_id_hex = identity.endpoint_id_hex()?;
    eprintln!(
        "cmux-tui-iroh: listening (endpoint {}…, tag {}, binding {}, session socket {})",
        log_id(&endpoint_id_hex),
        identity.tag,
        registration.binding_id,
        socket_path.display(),
    );

    let shared = ListenerShared {
        identity: Arc::new(identity.clone()),
        endpoint_id_hex: Arc::new(endpoint_id_hex),
        socket_path: Arc::new(socket_path),
        keys: Arc::new(Mutex::new(keys)),
        admitted: Arc::new(Mutex::new(HashMap::new())),
        unadmitted_permits: Arc::new(Semaphore::new(MAX_UNADMITTED_CONNECTIONS)),
    };

    spawn_relay_maintenance(endpoint.clone(), broker.clone(), identity.clone(), root.clone());
    spawn_revalidation(broker.clone(), shared.clone(), root.clone());

    let router =
        Router::builder(endpoint.clone()).accept(grant::TUI_ALPN, TuiProtocol { shared }).spawn();

    tokio::signal::ctrl_c().await.context("waiting for ctrl-c")?;
    eprintln!("cmux-tui-iroh: shutting down");
    router.shutdown().await.ok();
    endpoint.close().await;
    Ok(())
}

/// Mirrors the mux server's socket path resolution from `spec/transports.md`:
/// `$XDG_RUNTIME_DIR`, then `$TMPDIR`, then `/tmp`, joined with
/// `cmux-tui-<uid>/<session>.sock`.
pub fn default_session_socket(session: &str) -> PathBuf {
    let base = std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| std::env::var("TMPDIR").ok().filter(|value| !value.is_empty()))
        .unwrap_or_else(|| "/tmp".to_string());
    let uid = unsafe { libc::getuid() };
    Path::new(&base).join(format!("cmux-tui-{uid}")).join(format!("{session}.sock"))
}

#[derive(Debug, Clone)]
struct TuiProtocol {
    shared: ListenerShared,
}

impl std::fmt::Debug for ListenerShared {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ListenerShared")
    }
}

impl iroh::protocol::ProtocolHandler for TuiProtocol {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let shared = self.shared.clone();
        if let Err(error) = handle_connection(shared, connection).await {
            eprintln!("cmux-tui-iroh: connection ended: {error:#}");
        }
        Ok(())
    }
}

async fn handle_connection(shared: ListenerShared, connection: Connection) -> anyhow::Result<()> {
    let remote_hex = connection.remote_id().to_string();
    let connection_key = connection.stable_id();

    // Admission phase, bounded in concurrency, bytes, and time.
    let permit = shared
        .unadmitted_permits
        .clone()
        .try_acquire_owned()
        .context("too many unadmitted connections")?;
    let admission = tokio::time::timeout(
        ADMISSION_DEADLINE,
        admit_first_stream(&shared, &connection, &remote_hex),
    )
    .await;
    drop(permit);
    let (mut admission_send, admission_recv, grant_exp_unix) = match admission {
        Ok(Ok(parts)) => parts,
        Ok(Err(error)) => {
            eprintln!("cmux-tui-iroh: denied {}…: {error:#}", log_id(&remote_hex));
            connection.close(1u32.into(), b"admission denied");
            return Ok(());
        }
        Err(_) => {
            connection.close(1u32.into(), b"admission timeout");
            return Ok(());
        }
    };

    {
        let mut admitted = shared.admitted.lock().expect("admitted lock");
        if admitted.len() >= MAX_ADMITTED_CONNECTIONS {
            drop(admitted);
            connection.close(1u32.into(), b"connection limit");
            return Ok(());
        }
        admitted.insert(
            connection_key,
            AdmittedPeer {
                connection: connection.clone(),
                initiator_endpoint_id: remote_hex.clone(),
                grant_exp_unix,
            },
        );
    }
    eprintln!("cmux-tui-iroh: admitted {}…", log_id(&remote_hex));
    admission_send
        .write_all(format!("{}\n", serde_json::json!({"ok": true})).as_bytes())
        .await
        .context("writing admission ack")?;

    // The admission stream stays open as the connection's liveness channel:
    // its EOF (client went away) tears the connection down. The bound applies
    // during the read, not after, so a peer cannot force a large buffer.
    let watchdog_connection = connection.clone();
    tokio::spawn(async move {
        let mut reader = BufReader::new(admission_recv).take(ADMISSION_MAX_BYTES as u64);
        let mut sink = String::new();
        loop {
            sink.clear();
            match reader.read_line(&mut sink).await {
                Ok(0) | Err(_) => break,
                Ok(_) => reader.set_limit(ADMISSION_MAX_BYTES as u64),
            }
        }
        watchdog_connection.close(0u32.into(), b"admission stream closed");
    });

    // Grant expiry closes the session even if idle; the task exits early when
    // the connection closes so detached peers do not accumulate sleepers.
    let expiry_connection = connection.clone();
    let expiry_delay = (grant_exp_unix - unix_seconds_now()).max(0) as u64;
    tokio::spawn(async move {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(expiry_delay)) => {
                expiry_connection.close(0u32.into(), b"grant expired");
            }
            _ = expiry_connection.closed() => {}
        }
    });

    // Session streams: each is one protocol v10 JSON-lines client bridged to
    // the local session socket.
    let result = loop {
        match connection.accept_bi().await {
            Ok((send, recv)) => {
                let socket_path = shared.socket_path.clone();
                let peer = log_id(&remote_hex);
                tokio::spawn(async move {
                    if let Err(error) = bridge_stream(send, recv, &socket_path).await {
                        eprintln!("cmux-tui-iroh: session stream for {peer}… ended: {error:#}");
                    }
                });
            }
            Err(error) => break error,
        }
    };
    shared.admitted.lock().expect("admitted lock").remove(&connection_key);
    eprintln!("cmux-tui-iroh: connection {}… closed ({result})", log_id(&remote_hex));
    Ok(())
}

async fn admit_first_stream(
    shared: &ListenerShared,
    connection: &Connection,
    remote_hex: &str,
) -> anyhow::Result<(iroh::endpoint::SendStream, iroh::endpoint::RecvStream, i64)> {
    let (send, recv) = connection.accept_bi().await.context("waiting for admission stream")?;
    let mut reader = BufReader::new(recv).take(ADMISSION_MAX_BYTES as u64);
    let mut line = String::new();
    let read = reader.read_line(&mut line).await.context("reading admission frame")?;
    anyhow::ensure!(read > 0, "admission stream closed before a frame");
    anyhow::ensure!(line.ends_with('\n'), "admission frame exceeds the size bound");
    let frame: serde_json::Value =
        serde_json::from_str(line.trim()).context("admission frame is not JSON")?;
    anyhow::ensure!(
        frame.get("v").and_then(serde_json::Value::as_u64) == Some(1),
        "unsupported admission version"
    );
    let jws = frame
        .get("grant")
        .and_then(serde_json::Value::as_str)
        .context("admission frame missing grant")?;
    let keys = shared.keys.lock().expect("keys lock").clone();
    let claims = grant::verify_grant(jws, &keys, unix_seconds_now())?;
    let local = AcceptorIdentity {
        device_id: &shared.identity.device_id,
        tag: &shared.identity.tag,
        endpoint_id: &shared.endpoint_id_hex,
        platform: crate::broker::device_platform(),
    };
    grant::check_admission(&claims, &local, remote_hex)?;
    let recv = reader.into_inner().into_inner();
    Ok((send, recv, claims.exp))
}

/// Pumps one iroh bidirectional stream into a fresh connection to the local
/// session socket. Byte-for-byte: the protocol v10 JSON-lines schema crosses
/// unchanged, exactly like `cmux-tui relay` over SSH.
async fn bridge_stream(
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
    socket_path: &Path,
) -> anyhow::Result<()> {
    let unix = tokio::net::UnixStream::connect(socket_path)
        .await
        .with_context(|| format!("connecting to session socket {}", socket_path.display()))?;
    let (mut unix_read, mut unix_write) = unix.into_split();
    let to_unix = async {
        tokio::io::copy(&mut recv, &mut unix_write).await?;
        unix_write.shutdown().await?;
        Ok::<(), std::io::Error>(())
    };
    let from_unix = async {
        tokio::io::copy(&mut unix_read, &mut send).await?;
        send.finish().ok();
        Ok::<(), std::io::Error>(())
    };
    let (to_result, from_result) = tokio::join!(to_unix, from_unix);
    to_result.context("client-to-session copy")?;
    from_result.context("session-to-client copy")?;
    Ok(())
}

/// Revalidates broker state while admitted connections exist, at most every
/// 30 seconds. A discovery that no longer contains an admitted initiator's
/// endpoint (or this device's own binding) closes the affected connections.
/// Broker connectivity failure preserves connections and retries.
fn spawn_revalidation(
    broker: Arc<BrokerClient>,
    shared: ListenerShared,
    root: PathBuf,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(REVALIDATION_INTERVAL).await;
            let has_peers = !shared.admitted.lock().expect("admitted lock").is_empty();
            if !has_peers {
                continue;
            }
            let discovery = match broker.discover().await {
                Ok(discovery) => discovery,
                Err(error) => {
                    eprintln!(
                        "cmux-tui-iroh: revalidation deferred (broker unreachable): {error:#}"
                    );
                    continue;
                }
            };
            if let Ok(keys) = VerificationKeySet::from_value(&discovery.grant_verification_keys) {
                *shared.keys.lock().expect("keys lock") = keys;
                if let Ok(mut cache) = load_broker_cache(&root) {
                    cache.grant_verification_keys = Some(discovery.grant_verification_keys.clone());
                    let _ = save_broker_cache(&root, &cache);
                }
            }
            let active: std::collections::HashSet<String> =
                discovery.bindings.iter().map(|binding| binding.endpoint_id.clone()).collect();
            let self_active = active.contains(shared.endpoint_id_hex.as_str());
            let now = unix_seconds_now();
            let to_close: Vec<Connection> = {
                let admitted = shared.admitted.lock().expect("admitted lock");
                admitted
                    .values()
                    .filter(|peer| {
                        !self_active
                            || !active.contains(&peer.initiator_endpoint_id)
                            || peer.grant_exp_unix <= now
                    })
                    .map(|peer| peer.connection.clone())
                    .collect()
            };
            for connection in to_close {
                connection.close(0u32.into(), b"authorization revoked");
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use ed25519_dalek::Signer as _;
    use iroh::endpoint::presets;

    use crate::grant::{GrantClaims, GrantPeer, TUI_ALPN, TUI_ALPN_STR, TUI_SCOPE};

    #[test]
    fn socket_resolution_uses_runtime_dir_shape() {
        let path = default_session_socket("main");
        let text = path.to_string_lossy();
        assert!(text.contains("cmux-tui-"));
        assert!(text.ends_with("main.sock"));
    }

    fn test_key_set(signing: &ed25519_dalek::SigningKey, kid: &str) -> VerificationKeySet {
        let mut spki = vec![0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00];
        spki.extend_from_slice(signing.verifying_key().as_bytes());
        serde_json::from_value(serde_json::json!({
            "version": 1,
            "current_kid": kid,
            "keys": [{
                "kid": kid,
                "alg": "EdDSA",
                "spki_der_base64": base64::engine::general_purpose::STANDARD.encode(spki),
            }],
        }))
        .unwrap()
    }

    fn sign_grant(signing: &ed25519_dalek::SigningKey, kid: &str, claims: &GrantClaims) -> String {
        let header = serde_json::json!({"alg": "EdDSA", "typ": "cmux-pair-grant+jwt", "kid": kid});
        let header_b64 = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&header).unwrap());
        let claims_b64 = URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap());
        let signing_input = format!("{header_b64}.{claims_b64}");
        let signature = signing.sign(signing_input.as_bytes());
        format!("{signing_input}.{}", URL_SAFE_NO_PAD.encode(signature.to_bytes()))
    }

    /// Full server-leg proof over real iroh QUIC on localhost: a fake session
    /// socket answers one JSON line per request; a client is admitted with a
    /// signed grant and speaks JSON lines through the bridge; a second client
    /// with a grant naming a different acceptor is denied.
    #[tokio::test(flavor = "multi_thread")]
    async fn admits_bridges_and_denies_over_real_iroh() {
        let dir = tempfile::tempdir().unwrap();
        let socket_path = dir.path().join("session.sock");

        // Fake mux session socket: echoes each request line back inside data.
        let mux = tokio::net::UnixListener::bind(&socket_path).unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = mux.accept().await else { break };
                tokio::spawn(async move {
                    let (read, mut write) = stream.into_split();
                    let mut lines = BufReader::new(read).lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        let reply = serde_json::json!({"ok": true, "echo": line});
                        if write.write_all(format!("{reply}\n").as_bytes()).await.is_err() {
                            break;
                        }
                    }
                });
            }
        });

        // Acceptor (listener) identity and grant-signing authority.
        let acceptor_secret = iroh::SecretKey::generate();
        let acceptor_hex = acceptor_secret.public().to_string();
        let grant_signer = ed25519_dalek::SigningKey::from_bytes(&[42u8; 32]);
        let keys = test_key_set(&grant_signer, "test-kid");
        let identity = Identity {
            version: 1,
            secret_key_hex: acceptor_secret
                .to_bytes()
                .iter()
                .map(|byte| format!("{byte:02x}"))
                .collect(),
            device_id: "acceptor-device".to_string(),
            app_instance_id: "acceptor-instance".to_string(),
            tag: "boxa".to_string(),
            binding_id: None,
        };
        let shared = ListenerShared {
            identity: Arc::new(identity),
            endpoint_id_hex: Arc::new(acceptor_hex.clone()),
            socket_path: Arc::new(socket_path.clone()),
            keys: Arc::new(Mutex::new(keys)),
            admitted: Arc::new(Mutex::new(HashMap::new())),
            unadmitted_permits: Arc::new(Semaphore::new(MAX_UNADMITTED_CONNECTIONS)),
        };

        // Localhost iroh endpoints: no relays needed, direct addresses only.
        let server = iroh::Endpoint::builder(presets::Minimal)
            .secret_key(acceptor_secret)
            .alpns(vec![TUI_ALPN.to_vec()])
            .bind()
            .await
            .unwrap();
        let server_addr = server.addr();
        let router =
            Router::builder(server.clone()).accept(TUI_ALPN, TuiProtocol { shared }).spawn();

        let client_secret = iroh::SecretKey::generate();
        let client_hex = client_secret.public().to_string();
        let client = iroh::Endpoint::builder(presets::Minimal)
            .secret_key(client_secret)
            .bind()
            .await
            .unwrap();

        let now = unix_seconds_now();
        let claims = GrantClaims {
            jti: "3fa07c60-0000-4000-8000-000000000001".to_string(),
            iat: now,
            nbf: now - 5,
            exp: now + 300,
            alpn: TUI_ALPN_STR.to_string(),
            scope: TUI_SCOPE.to_string(),
            initiator: GrantPeer {
                binding_id: "b-init".to_string(),
                device_id: "initiator-device".to_string(),
                tag: "tui-test".to_string(),
                platform: "mac".to_string(),
                endpoint_id: client_hex.clone(),
                identity_generation: 1,
            },
            acceptor: GrantPeer {
                binding_id: "b-acc".to_string(),
                device_id: "acceptor-device".to_string(),
                tag: "boxa".to_string(),
                platform: crate::broker::device_platform().to_string(),
                endpoint_id: acceptor_hex.clone(),
                identity_generation: 1,
            },
        };
        let grant_jws = sign_grant(&grant_signer, "test-kid", &claims);

        // Admission.
        let connection = client.connect(server_addr.clone(), TUI_ALPN).await.unwrap();
        let (mut admission_send, admission_recv) = connection.open_bi().await.unwrap();
        let frame = serde_json::json!({"v": 1, "grant": grant_jws});
        admission_send.write_all(format!("{frame}\n").as_bytes()).await.unwrap();
        let mut ack_reader = BufReader::new(admission_recv);
        let mut ack = String::new();
        tokio::time::timeout(Duration::from_secs(10), ack_reader.read_line(&mut ack))
            .await
            .unwrap()
            .unwrap();
        let ack_json: serde_json::Value = serde_json::from_str(ack.trim()).unwrap();
        assert_eq!(ack_json.get("ok").and_then(serde_json::Value::as_bool), Some(true));

        // Bridged protocol stream: JSON line in, JSON line out, byte-faithful.
        let (mut session_send, session_recv) = connection.open_bi().await.unwrap();
        session_send.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\n").await.unwrap();
        let mut session_reader = BufReader::new(session_recv);
        let mut reply = String::new();
        tokio::time::timeout(Duration::from_secs(10), session_reader.read_line(&mut reply))
            .await
            .unwrap()
            .unwrap();
        let reply_json: serde_json::Value = serde_json::from_str(reply.trim()).unwrap();
        assert_eq!(
            reply_json.get("echo").and_then(serde_json::Value::as_str),
            Some("{\"id\":1,\"cmd\":\"identify\"}")
        );

        // A grant naming a DIFFERENT acceptor device must be denied and the
        // connection closed without any bridging.
        let evil_secret = iroh::SecretKey::generate();
        let evil_hex = evil_secret.public().to_string();
        let evil =
            iroh::Endpoint::builder(presets::Minimal).secret_key(evil_secret).bind().await.unwrap();
        let mut evil_claims = claims.clone();
        evil_claims.initiator.endpoint_id = evil_hex;
        evil_claims.acceptor.device_id = "some-other-device".to_string();
        let evil_grant = sign_grant(&grant_signer, "test-kid", &evil_claims);
        let evil_connection = evil.connect(server_addr, TUI_ALPN).await.unwrap();
        let (mut evil_send, evil_recv) = evil_connection.open_bi().await.unwrap();
        let evil_frame = serde_json::json!({"v": 1, "grant": evil_grant});
        evil_send.write_all(format!("{evil_frame}\n").as_bytes()).await.unwrap();
        let mut evil_reader = BufReader::new(evil_recv);
        let mut evil_ack = String::new();
        let denied =
            tokio::time::timeout(Duration::from_secs(10), evil_reader.read_line(&mut evil_ack))
                .await
                .unwrap();
        // Either the deny closed the stream (EOF/reset) before a line arrived,
        // or no ok:true line was produced.
        match denied {
            Ok(0) | Err(_) => {}
            Ok(_) => {
                let value: serde_json::Value =
                    serde_json::from_str(evil_ack.trim()).unwrap_or_default();
                assert_ne!(value.get("ok").and_then(serde_json::Value::as_bool), Some(true));
            }
        }
        tokio::time::timeout(Duration::from_secs(10), evil_connection.closed()).await.unwrap();

        connection.close(0u32.into(), b"test done");
        router.shutdown().await.ok();
        client.close().await;
        evil.close().await;
        server.close().await;
    }
}
