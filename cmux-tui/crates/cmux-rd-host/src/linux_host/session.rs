//! One approved hub session served by this desktop, the way the Mac's `MacScreenRdHost`
//! serves it: wait for the viewer's cmux.rd/1 offer (its `fpSig` checked against the
//! ticket's viewer key), start `cmux-rd serve`, send it the setup line, answer with this
//! side's signed session key, displays and candidates, relay candidates both ways, report
//! the path, and end on `bye`, the process ending, or the hub's revocation.

use super::b64;
use super::hub::Hub;
use super::net::Message;
use super::rd_doc::{self, RdDocument};
use crate::Res;
use cmux_process::{Child, Command, Stdio};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::process::ChildStdin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::sync::Arc;
use std::time::Duration;

/// A `session.ticket` push for the host role.
#[derive(Debug, Clone)]
pub struct Ticket {
    pub session_id: String,
    pub jws: String,
    pub signal_url: String,
    pub ice: Value,
    pub peer_id: String,
    pub peer_name: String,
    pub peer_key: String,
    pub scope: String,
}

impl Ticket {
    /// The push, when it is a host ticket whose JWS names this session, the host role and the
    /// same viewer key as the push.
    pub fn from_push(push: &Value) -> Res<Self> {
        let s = |v: &Value| v.as_str().unwrap_or_default().to_owned();
        let ticket = Self {
            session_id: s(&push["sessionId"]),
            jws: s(&push["ticket"]),
            signal_url: s(&push["signalURL"]),
            ice: push["ice"].clone(),
            peer_id: s(&push["peer"]["id"]),
            peer_name: s(&push["peer"]["name"]),
            peer_key: s(&push["peer"]["signingKey"]),
            scope: s(&push["scope"]),
        };
        if push["role"].as_str() != Some("host") {
            return Err("not a host ticket".into());
        }
        let claims = jws_payload(&ticket.jws).ok_or("the ticket is not a compact JWS")?;
        if claims["sid"].as_str() != Some(&ticket.session_id)
            || claims["role"].as_str() != Some("host")
            || claims["peerKey"].as_str() != Some(&ticket.peer_key)
            || ticket.peer_key.is_empty()
        {
            return Err("the ticket names another session, role or viewer key".into());
        }
        Ok(ticket)
    }
}

/// A compact JWS's payload (the hub's Session DO verifies the signature; this side only reads it).
pub fn jws_payload(jws: &str) -> Option<Value> {
    let mut parts = jws.split('.');
    let (_, payload, _, None) = (parts.next()?, parts.next()?, parts.next()?, parts.next()) else {
        return None;
    };
    serde_json::from_slice(&b64::decode(payload)?).ok()
}

/// Options passed to `cmux-rd serve` (`--display`, `--xauthority`, `--capture`).
#[derive(Debug, Clone, Default)]
pub struct ServeArgs(pub Vec<String>);

/// How a session ended: the reason, whether the viewer had connected, and the reason to give
/// the hub (`/end`) when this side ends it.
#[derive(Debug, PartialEq)]
pub struct Ended {
    pub reason: String,
    pub connected: bool,
    pub tell_hub: Option<&'static str>,
}

struct Serve {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<Value>,
}

impl Serve {
    fn start(args: &ServeArgs) -> Res<Self> {
        let exe = std::env::current_exe()?;
        let mut child = Command::new(exe)
            .arg("serve")
            .args(&args.0)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let stdin = child.stdin.take();
        let (tx, lines) = mpsc::channel();
        std::thread::Builder::new().name("rd-serve-out".into()).spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if let Ok(value) = serde_json::from_str::<Value>(&line) {
                    if tx.send(value).is_err() {
                        break;
                    }
                }
            }
        })?;
        Ok(Self { child, stdin, lines })
    }

    fn send(&mut self, value: &Value) {
        if let Some(stdin) = self.stdin.as_mut() {
            let mut line = value.to_string();
            line.push('\n');
            if stdin.write_all(line.as_bytes()).and_then(|()| stdin.flush()).is_err() {
                self.stdin = None;
            }
        }
    }

    /// `stop`, then end of input; the process stops its session and exits (killed after 3 s).
    fn stop(mut self) {
        self.send(&json!({ "stop": true }));
        self.stdin = None;
        if let Ok(Some(_)) = self.child.wait_timeout(Duration::from_secs(3)) {
            return;
        }
        // Our own child, by its handle (dropping it would end it too).
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Serves `ticket` until it ends. `view_only` comes from the ticket's scope and this
/// desktop's consent; `stop` is set by a revocation, an end, or the host stopping.
pub fn serve(
    hub: &Hub,
    ticket: &Ticket,
    view_only: bool,
    args: &ServeArgs,
    stop: &Arc<AtomicBool>,
) -> Ended {
    let mut ws = match hub.session_socket(&ticket.signal_url, &ticket.jws) {
        Ok(ws) => ws,
        Err(e) => {
            return Ended {
                reason: format!("signaling: {e}"),
                connected: false,
                tell_hub: Some("failed"),
            }
        }
    };
    let mut serve: Option<Serve> = None;
    let mut answer: Option<RdDocument> = None;
    let (mut answered, mut connected, mut signaling) = (false, false, true);
    let ended = loop {
        if stop.load(Ordering::SeqCst) {
            break Ended { reason: "stopped".into(), connected, tell_hub: None };
        }
        // The host process's lines.
        if let Some(s) = serve.as_mut() {
            let mut finished = None;
            loop {
                match s.lines.try_recv() {
                    Ok(line) => {
                        if let Some(displays) = line["displays"].as_array() {
                            let doc = answer.get_or_insert_with(RdDocument::default);
                            doc.displays = displays
                                .iter()
                                .filter_map(|d| {
                                    Some((d[0].as_u64()? as u32, d[1].as_u64()? as u32))
                                })
                                .collect();
                            doc.current_display = line["current"].as_u64().map(|c| c as usize);
                        }
                        if let Some(key) = line["key"].as_str() {
                            answer.get_or_insert_with(RdDocument::default).key = key.to_owned();
                        }
                        if let Some(candidate) = line["candidate"].as_str() {
                            if answered {
                                let frame = json!({"type": "candidate", "candidate": candidate, "sdpMid": "cmux-rd", "sdpMLineIndex": 0});
                                let _ = ws.send_text(&frame.to_string());
                            } else if let Some(doc) = answer.as_mut() {
                                doc.candidates.push(candidate.to_owned());
                            }
                        }
                        // The answer goes once every candidate this side will find is known.
                        if line["candidates_done"].as_bool() == Some(true) && !answered {
                            if let Some(doc) = answer.as_ref().filter(|d| !d.key.is_empty()) {
                                answered = true;
                                match signed("answer", &doc.text(), &ticket.session_id, hub) {
                                    Ok(frame) => {
                                        if let Err(e) = ws.send_text(&frame) {
                                            eprintln!("linux-host: answer not sent: {e}");
                                        }
                                    }
                                    Err(e) => eprintln!("linux-host: answer not signed: {e}"),
                                }
                            }
                        }
                        if line["connected"].as_bool() == Some(true) && !connected {
                            connected = true;
                            eprintln!(
                                "linux-host: {} is {} this desktop",
                                super::printable(&ticket.peer_name),
                                if view_only { "viewing" } else { "controlling" }
                            );
                        }
                        if let Some(kind) = line["path"]["kind"].as_str() {
                            let path = if rd_doc::is_relayed(kind) { "relay" } else { "direct" };
                            let _ =
                                ws.send_text(&json!({"type": "path", "path": path}).to_string());
                        }
                        if let Some(message) = line["status"]["message"].as_str() {
                            eprintln!(
                                "cmux-rd linux-host: session {}: {}",
                                super::printable(&ticket.session_id),
                                super::printable(message)
                            );
                        }
                        if let Some(reason) = line["ended"].as_str() {
                            finished = Some(reason.to_owned());
                            break;
                        }
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        finished = Some("the screen host stopped".into());
                        break;
                    }
                }
            }
            if let Some(reason) = finished {
                let tell_hub = if connected { None } else { Some("failed") };
                break Ended { reason, connected, tell_hub };
            }
        }
        // The viewer's signals. A connected session outlives lost signaling, not the hub's close.
        if !signaling {
            std::thread::sleep(Duration::from_millis(100));
            continue;
        }
        let text = match ws.recv(Duration::from_millis(100)) {
            Ok(None) => continue,
            Ok(Some(Message::Text(text))) => text,
            Ok(Some(Message::Closed(code, why))) if close_ends_session(code) => {
                // The hub's word (revoked, sharing off, ended, replaced): the media stops too.
                break Ended {
                    reason: format!(
                        "the hub closed the session ({code} {})",
                        super::printable(&why)
                    ),
                    connected,
                    tell_hub: None,
                };
            }
            Ok(Some(Message::Closed(..))) | Err(_) => {
                signaling = false;
                if serve.is_none() || !connected {
                    break Ended {
                        reason: "signaling closed before the viewer connected".into(),
                        connected,
                        tell_hub: None,
                    };
                }
                continue;
            }
        };
        let Ok(frame) = serde_json::from_str::<Value>(&text) else { continue };
        match frame["type"].as_str() {
            Some("offer") => {
                let sdp = frame["sdp"].as_str().unwrap_or_default();
                let fp_sig = frame["fpSig"].as_str().unwrap_or_default();
                if !rd_doc::verify_fp_sig(
                    sdp,
                    fp_sig,
                    &ticket.session_id,
                    "viewer",
                    &ticket.peer_key,
                ) {
                    let _ = ws.send_text(r#"{"type":"bye"}"#);
                    break Ended {
                        reason: "the viewer's offer is not signed by its device key".into(),
                        connected,
                        tell_hub: Some("failed"),
                    };
                }
                if serve.is_some() {
                    continue;
                }
                let Some(offer) = RdDocument::parse(sdp) else {
                    // A WebRTC viewer (the iPhone's, or an old Mac): this host serves cmux.rd/1 only.
                    let _ = ws.send_text(r#"{"type":"bye"}"#);
                    break Ended {
                        reason:
                            "the viewer offered WebRTC; this Linux host serves cmux.rd/1 viewers"
                                .into(),
                        connected,
                        tell_hub: Some("failed"),
                    };
                };
                let mut started = match Serve::start(args) {
                    Ok(s) => s,
                    Err(e) => {
                        break Ended {
                            reason: format!("the screen host could not start: {e}"),
                            connected,
                            tell_hub: Some("failed"),
                        }
                    }
                };
                started.send(&setup_line(ticket, &offer, view_only));
                for candidate in &offer.candidates {
                    started.send(&json!({ "candidate": candidate }));
                }
                serve = Some(started);
            }
            Some("candidate") if frame["sdpMid"].as_str() == Some("cmux-rd") => {
                if let (Some(s), Some(c)) = (serve.as_mut(), frame["candidate"].as_str()) {
                    s.send(&json!({ "candidate": c }));
                }
            }
            Some("bye") => break Ended { reason: "bye".into(), connected, tell_hub: None },
            _ => {}
        }
    };
    if let Some(s) = serve {
        s.stop();
    }
    ws.close();
    ended
}

/// Whether a signaling close `code` ends the session rather than only its signaling. Only
/// lost transport is survivable (going away, no code, abnormal, server error, restart, try
/// later, bad gateway): every code the hub chooses itself (1000 on /end or bye, 4000 when
/// another socket took this role, 4002 on revocation or sharing off, any other) ends it.
pub fn close_ends_session(code: u16) -> bool {
    !matches!(code, 1001 | 1005 | 1006 | 1011 | 1012 | 1013 | 1014)
}

/// `{"type": .., "sdp": .., "fpSig": ..}` signed for the host role.
fn signed(kind: &str, sdp: &str, session: &str, hub: &Hub) -> Res<String> {
    let fingerprint = rd_doc::fingerprint_of(sdp).ok_or("no fingerprint")?;
    let sig = hub.sign(&rd_doc::fingerprint_message(session, "host", &fingerprint))?;
    Ok(json!({ "type": kind, "sdp": sdp, "fpSig": b64::encode(&sig) }).to_string())
}

/// The setup line `cmux-rd serve` reads first (the Mac's `Setup`).
pub fn setup_line(ticket: &Ticket, offer: &RdDocument, view_only: bool) -> Value {
    let (stun, turn) = rd_doc::servers(&ticket.ice);
    json!({
        "session": ticket.session_id,
        "peer_key": offer.key,
        "viewer": { "user": ticket.peer_id, "install": ticket.peer_id },
        "scope": if view_only { "view" } else { "control" },
        "stun": stun,
        "turn": turn,
        "display": offer.display.map_or_else(|| "main".to_owned(), |d| d.to_string()),
        "max_fps": offer.max_fps.map(|f| f.min(120)),
        "max_width": offer.max_width,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jws(payload: &Value) -> String {
        format!(
            "eyJhbGciOiJFUzI1NiJ9.{}.c2ln",
            b64::encode(payload.to_string().as_bytes())
                .trim_end_matches('=')
                .replace('+', "-")
                .replace('/', "_")
        )
    }

    fn push(role: &str, sid_in_jws: &str, key_in_jws: &str) -> Value {
        json!({
            "type": "session.ticket", "sessionId": "s1", "role": role, "scope": "view",
            "ticket": jws(&json!({"sid": sid_in_jws, "role": role, "peerKey": key_in_jws})),
            "signalURL": "wss://hub.example/v1/sessions/s1/ws", "ice": [],
            "peer": {"id": "v1", "name": "Mac", "signingKey": "KEY"}
        })
    }

    #[test]
    fn host_tickets_must_agree_with_their_jws() {
        assert!(Ticket::from_push(&push("host", "s1", "KEY")).is_ok());
        assert!(Ticket::from_push(&push("viewer", "s1", "KEY")).is_err());
        assert!(Ticket::from_push(&push("host", "s2", "KEY")).is_err());
        assert!(Ticket::from_push(&push("host", "s1", "OTHER")).is_err());
    }

    #[test]
    fn the_hubs_own_closes_end_the_session() {
        // The Session DO closes 4002 on revocation or sharing off, 1000 on /end or bye, 4000
        // when another socket took this role. Any code it may choose ends the media too.
        for code in [1000, 1008, 4000, 4002, 4004, 4999] {
            assert!(close_ends_session(code), "{code} must end the session");
        }
        // Lost transport, not the hub's word: a connected session outlives it.
        for code in [1001, 1005, 1006, 1011, 1012, 1013, 1014] {
            assert!(!close_ends_session(code), "{code} is signaling loss");
        }
    }

    #[test]
    fn setup_line_is_the_macs_and_view_only_wins() {
        let ticket = Ticket::from_push(&push("host", "s1", "KEY")).unwrap();
        let offer = RdDocument {
            key: "ab".repeat(32),
            max_fps: Some(240),
            display: Some(1),
            ..RdDocument::default()
        };
        let line = setup_line(&ticket, &offer, true);
        assert_eq!(line["scope"], "view");
        assert_eq!(line["max_fps"], 120);
        assert_eq!(line["display"], "1");
        assert_eq!(line["viewer"]["user"], "v1");
        assert_eq!(setup_line(&ticket, &RdDocument::default(), false)["display"], "main");
        assert_eq!(setup_line(&ticket, &RdDocument::default(), false)["scope"], "control");
    }
}
