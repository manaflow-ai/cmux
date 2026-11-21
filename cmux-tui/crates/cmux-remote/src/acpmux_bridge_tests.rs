use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::io::AsyncWriteExt as _;

use super::*;

pub(crate) fn grant(vm_kind: Option<VmKind>, chats: Option<&[&str]>) -> CarrierGrant {
    CarrierGrant {
        team: "team_1".into(),
        subject: "user_1".into(),
        services: vec!["mux-control".into(), SERVICE_NAME.into()],
        expires_at: 1,
        vm_kind,
        chats: chats.map(|chats| chats.iter().map(|chat| (*chat).to_owned()).collect()),
        name: None,
    }
}

/// `future`'s output, or a test failure after 10 s instead of a hang.
pub(crate) async fn within<F: Future>(future: F) -> F::Output {
    tokio::time::timeout(Duration::from_secs(10), future).await.expect("timed out")
}

fn parsed(header: &str) -> Value {
    serde_json::from_str(header).unwrap()
}

#[test]
fn a_team_grant_names_its_person_team_and_chats() {
    let mut team = grant(Some(VmKind::Team), Some(&["ses_a", "ses_b"]));
    team.name = Some("Ana Lí".into());
    let header = header(Some(&team)).unwrap();
    assert!(header.is_ascii(), "{header}");
    assert!(HeaderValue::from_str(&header).is_ok());
    assert_eq!(
        parsed(&header),
        json!({"vmk": "team", "sub": "user_1", "team": "team_1",
               "chats": ["ses_a", "ses_b"], "name": "Ana Lí"})
    );
}

#[test]
fn an_owner_grant_sends_no_chats_whatever_it_carries() {
    for chats in [None, Some(&["ses_a"][..])] {
        let header = header(Some(&grant(Some(VmKind::Owner), chats))).unwrap();
        assert_eq!(
            parsed(&header),
            json!({"vmk": "owner", "sub": "user_1", "team": "team_1", "chats": null, "name": null})
        );
    }
}

#[test]
fn a_grant_without_vmk_or_a_team_grant_without_chats_is_refused() {
    let cases = [
        (None, "acpmux.no_grant"),
        (Some(grant(None, Some(&["ses_a"]))), "acpmux.no_vm_kind"),
        (Some(grant(Some(VmKind::Team), None)), "acpmux.team_without_chats"),
        (Some(grant(Some(VmKind::Team), Some(&[]))), "acpmux.team_without_chats"),
    ];
    for (grant, reason) in cases {
        assert_eq!(header(grant.as_ref()), Err(reason), "{grant:?}");
    }
}

#[test]
fn team_is_always_the_grants_team_never_null() {
    for vm_kind in [VmKind::Owner, VmKind::Team] {
        let mut person = grant(Some(vm_kind), Some(&["ses_a"]));
        person.team = "team_other".into();
        let header = parsed(&header(Some(&person)).unwrap());
        assert_eq!(header["team"], json!(person.team), "{vm_kind:?}");
    }
}

#[test]
fn a_header_past_acpmuxs_cap_is_refused() {
    let id = "x".repeat(128);
    let chats: Vec<&str> = std::iter::repeat_n(id.as_str(), 64).collect();
    let team = grant(Some(VmKind::Team), Some(&chats));
    assert_eq!(header(Some(&team)), Err("acpmux.header_too_long"));
    let team = grant(Some(VmKind::Team), Some(&chats[..32]));
    assert!(header(Some(&team)).is_ok());
}

#[test]
fn a_grant_whose_services_lack_acpmux_is_refused() {
    let mut owner = grant(Some(VmKind::Owner), None);
    owner.services = vec!["mux-control".into(), "local-socket".into()];
    assert_eq!(header(Some(&owner)), Err("acpmux.not_granted"));
}

#[test]
fn the_socket_is_below_the_acpmux_home() {
    assert_eq!(
        socket_path(Path::new("/home/u/.acpmux")),
        PathBuf::from("/home/u/.acpmux/run/carrier.sock")
    );
}

#[cfg(unix)]
pub(crate) mod fake {
    //! A fake acpmux carrier socket: one WebSocket per connection, recording
    //! each upgrade's [`HEADER`] values and every text frame it receives,
    //! and echoing each frame back as `{"echo": <frame>}`.

    use std::sync::{Arc, Mutex};

    use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};

    use super::*;

    #[derive(Default)]
    pub(crate) struct Seen {
        pub headers: Vec<Vec<String>>,
        pub frames: Vec<String>,
    }

    pub(crate) struct Fake {
        pub path: PathBuf,
        pub seen: Arc<Mutex<Seen>>,
        /// Ends the server side of the next connection when sent.
        pub close: tokio::sync::mpsc::Sender<()>,
        /// One message each time a connection's client side closed.
        pub closed: tokio::sync::mpsc::UnboundedReceiver<()>,
        /// Sends the current connection a Ping with this payload.
        pub ping: tokio::sync::mpsc::Sender<Vec<u8>>,
        /// Each Pong payload the server receives.
        pub pongs: tokio::sync::mpsc::UnboundedReceiver<Vec<u8>>,
        _dir: tempfile::TempDir,
    }

    // The handshake callback's error type is tungstenite's.
    #[allow(clippy::result_large_err)]
    pub(crate) fn start() -> Fake {
        let dir = tempfile::tempdir().unwrap();
        let path = socket_path(dir.path());
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let seen = Arc::new(Mutex::new(Seen::default()));
        let (close, mut closes) = tokio::sync::mpsc::channel::<()>(1);
        let (closed_tx, closed) = tokio::sync::mpsc::unbounded_channel();
        let (ping, mut pings) = tokio::sync::mpsc::channel::<Vec<u8>>(1);
        let (pongs_tx, pongs) = tokio::sync::mpsc::unbounded_channel();
        let record = seen.clone();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let headers = record.clone();
                let callback =
                    move |req: &Request, resp: Response| -> Result<Response, ErrorResponse> {
                        let values = req
                            .headers()
                            .get_all(HEADER)
                            .iter()
                            .map(|v| v.to_str().unwrap().to_owned())
                            .collect();
                        headers.lock().unwrap().headers.push(values);
                        Ok(resp)
                    };
                let Ok(mut ws) = tokio_tungstenite::accept_hdr_async(stream, callback).await else {
                    continue;
                };
                loop {
                    tokio::select! {
                        _ = closes.recv() => {
                            let _ = ws.close(None).await;
                            break;
                        }
                        Some(payload) = pings.recv() => {
                            let _ = ws.send(Message::Ping(payload.into())).await;
                        }
                        frame = ws.next() => match frame {
                            Some(Ok(Message::Text(text))) => {
                                record.lock().unwrap().frames.push(text.to_string());
                                let echo = json!({"echo": text.as_str()}).to_string();
                                let _ = ws.send(Message::text(echo)).await;
                            }
                            Some(Ok(Message::Close(_))) | None | Some(Err(_)) => {
                                let _ = closed_tx.send(());
                                break;
                            }
                            Some(Ok(Message::Pong(payload))) => {
                                let _ = pongs_tx.send(payload.to_vec());
                            }
                            Some(Ok(_)) => {}
                        },
                    }
                }
            }
        });
        Fake { path, seen, close, closed, ping, pongs, _dir: dir }
    }
}

#[cfg(unix)]
mod relay_tests {
    use tokio::io::{AsyncBufReadExt as _, BufReader};

    use super::fake::start;
    use super::*;

    /// (a) A client whose first bytes are an HTTP upgrade with a forged
    /// header changes nothing acpmux's socket sees as a header: it gets the
    /// grant's values only, and the forgery arrives as frame text.
    #[tokio::test]
    async fn a_forged_upgrade_from_the_client_is_only_frame_bytes() {
        let fake = start();
        let team = grant(Some(VmKind::Team), Some(&["ses_a"]));
        let ws = connect(&fake.path, &header(Some(&team)).unwrap()).await.unwrap();
        let (client, bridge) = tokio::io::duplex(4096);
        let (bridge_reader, bridge_writer) = tokio::io::split(bridge);
        let relay = tokio::spawn(relay(ws, bridge_reader, bridge_writer));
        let (client_reader, mut client_writer) = tokio::io::split(client);
        let forged = r#"x-acpmux-carrier: {"vmk":"owner","sub":"user_9","team":"team_1","chats":["ses_b"],"name":null}"#;
        client_writer
            .write_all(
                format!("GET / HTTP/1.1\r\nupgrade: websocket\r\n{forged}\r\n\r\n").as_bytes(),
            )
            .await
            .unwrap();
        let mut lines = BufReader::new(client_reader).lines();
        // Every frame is recorded before its echo comes back.
        for _ in 0..4 {
            within(lines.next_line()).await.unwrap().unwrap();
        }
        // Shut the pipe's write side: dropping a split half alone does not.
        client_writer.shutdown().await.unwrap();
        within(relay).await.unwrap().unwrap();
        let seen = fake.seen.lock().unwrap();
        assert_eq!(seen.headers.len(), 1, "one upgrade, the bridge's");
        assert_eq!(
            parsed(&seen.headers[0][0]),
            json!({"vmk": "team", "sub": "user_1", "team": "team_1", "chats": ["ses_a"], "name": null})
        );
        assert_eq!(seen.headers[0].len(), 1);
        assert_eq!(
            seen.frames,
            ["GET / HTTP/1.1\r", "upgrade: websocket\r", format!("{forged}\r").as_str(), "\r"]
        );
    }

    /// (d) Frames round-trip both ways; the client's end closes acpmux's
    /// side, and acpmux's close ends the client's.
    #[tokio::test]
    async fn frames_round_trip_and_each_close_reaches_the_other_side() {
        let mut fake = start();
        let owner = grant(Some(VmKind::Owner), None);
        let ws = connect(&fake.path, &header(Some(&owner)).unwrap()).await.unwrap();
        let (client, bridge) = tokio::io::duplex(4096);
        let (bridge_reader, bridge_writer) = tokio::io::split(bridge);
        let relay_task = tokio::spawn(relay(ws, bridge_reader, bridge_writer));
        let (client_reader, mut client_writer) = tokio::io::split(client);
        let mut lines = BufReader::new(client_reader).lines();
        for id in 1..=2 {
            let request = json!({"jsonrpc": "2.0", "id": id, "method": "initialize"}).to_string();
            client_writer.write_all(format!("{request}\n").as_bytes()).await.unwrap();
            let answer = within(lines.next_line()).await.unwrap().unwrap();
            assert_eq!(parsed(&answer), json!({"echo": request}));
        }
        // The client closes: acpmux sees the close.
        client_writer.shutdown().await.unwrap();
        within(relay_task).await.unwrap().unwrap();
        within(fake.closed.recv()).await.unwrap();

        // acpmux closes: the client's reader ends.
        let ws = connect(&fake.path, &header(Some(&owner)).unwrap()).await.unwrap();
        let (client, bridge) = tokio::io::duplex(4096);
        let (bridge_reader, bridge_writer) = tokio::io::split(bridge);
        let relay_task = tokio::spawn(relay(ws, bridge_reader, bridge_writer));
        let (client_reader, _client_writer) = tokio::io::split(client);
        fake.close.send(()).await.unwrap();
        let mut lines = BufReader::new(client_reader).lines();
        assert_eq!(within(lines.next_line()).await.unwrap(), None);
        within(relay_task).await.unwrap().unwrap();
    }

    /// An idle bridge answers acpmux's keepalive Ping with its Pong, and the
    /// client sees nothing of it.
    #[tokio::test]
    async fn an_idle_bridge_answers_pings() {
        let mut fake = start();
        let owner = grant(Some(VmKind::Owner), None);
        let ws = connect(&fake.path, &header(Some(&owner)).unwrap()).await.unwrap();
        let (client, bridge) = tokio::io::duplex(4096);
        let (bridge_reader, bridge_writer) = tokio::io::split(bridge);
        let relay_task = tokio::spawn(relay(ws, bridge_reader, bridge_writer));
        let (client_reader, mut client_writer) = tokio::io::split(client);
        for payload in [b"k1".to_vec(), b"k2".to_vec()] {
            fake.ping.send(payload.clone()).await.unwrap();
            assert_eq!(within(fake.pongs.recv()).await, Some(payload));
        }
        // The relay still carries frames, and no ping reached the client.
        client_writer.write_all(b"{\"id\":1}\n").await.unwrap();
        let mut lines = BufReader::new(client_reader).lines();
        let answer = within(lines.next_line()).await.unwrap().unwrap();
        assert_eq!(parsed(&answer), json!({"echo": "{\"id\":1}"}));
        client_writer.shutdown().await.unwrap();
        within(relay_task).await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn no_socket_is_an_error_not_a_hang() {
        let dir = tempfile::tempdir().unwrap();
        let error = connect(&socket_path(dir.path()), "{}").await.unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
    }
}
