//! One approved hub session served by this desktop, the way the Mac's `MacScreenRdHost`
//! serves it: wait for the viewer's cmux.rd/1 offer (its `fpSig` checked against the
//! ticket's viewer key), start the helper (`cmux-rd serve`, a [`ServeCommand`]), send it the
//! setup line, answer with this side's signed session key, displays and candidates, relay
//! candidates both ways, report the path, and end on `bye`, the process ending, or the hub's
//! revocation.

use crate::b64;
use crate::hub::Hub;
use crate::net::Message;
use crate::rd_doc::{self, RdDocument};
use crate::Res;
use cmux_process::{Child, Command, Stdio};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
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
        Self::from_push_as(push, "host")
    }

    /// The push, when it is a `role` ticket (`host`, or `viewer` for `cmux-rd view`) whose JWS
    /// names this session, that role and the same peer key as the push.
    #[allow(
        clippy::indexing_slicing,
        reason = "serde_json's Value index reads Null for a missing key"
    )]
    pub fn from_push_as(push: &Value, role: &str) -> Res<Self> {
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
        if push["role"].as_str() != Some(role) {
            return Err(format!("not a {role} ticket").into());
        }
        let claims = jws_payload(&ticket.jws).ok_or("the ticket is not a compact JWS")?;
        if claims["sid"].as_str() != Some(&ticket.session_id)
            || claims["role"].as_str() != Some(role)
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

/// The cmux.rd/1 helper a session starts, and how this side names itself in the log.
#[derive(Debug, Clone)]
pub struct ServeCommand {
    pub program: PathBuf,
    /// What follows the program, e.g. `["serve", "--display", ":0"]`.
    pub args: Vec<String>,
    /// macOS: the helper becomes its own responsible process, so Screen Recording and
    /// Accessibility are checked against its own signature, in its own session (`setsid`).
    /// Elsewhere it changes nothing.
    pub disclaim: bool,
    /// The prefix of this side's log lines, e.g. `linux-host` (`linux-host: answer not sent`).
    pub log_prefix: String,
    /// The prefix of the helper's own status lines this side passes on, e.g.
    /// `cmux-rd linux-host` (`cmux-rd linux-host: session <id>: <message>`).
    pub status_prefix: String,
}

/// How a session ended: the reason, whether the viewer had connected, and the reason to give
/// the hub (`/end`) when this side ends it ([`failed_reason`] for a session it could not serve).
#[derive(Debug, PartialEq)]
pub struct Ended {
    pub reason: String,
    pub connected: bool,
    pub tell_hub: Option<String>,
}

/// The longest `/end` reason the hub keeps, in UTF-16 units (it cuts a longer one there).
pub const HUB_REASON_MAX: usize = 100;

/// The `/end` reason for a session this side could not serve: `failed: <why>`, so the viewer's
/// card says why (the Mac's `MacScreenEndReason` reads every `failed` prefix as a failure and
/// shows the rest) instead of guessing that the host is asleep or offline. `why` is made
/// printable on one line, a `failed:` that cmux-rd already put in front is not doubled, and the
/// whole is cut to [`HUB_REASON_MAX`] on a character boundary.
pub fn failed_reason(why: &str) -> String {
    let why = crate::printable(&why.replace(['\n', '\r', '\t'], " "));
    let mut why = why.trim();
    while let Some(rest) = why.strip_prefix("failed:") {
        why = rest.trim_start();
    }
    let mut out = String::from("failed");
    if why.is_empty() {
        return out;
    }
    out.push_str(": ");
    let mut units = out.len();
    for c in why.chars() {
        units += c.len_utf16();
        if units > HUB_REASON_MAX {
            break;
        }
        out.push(c);
    }
    out.truncate(out.trim_end().len());
    out
}

struct Serve {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<Value>,
}

impl Serve {
    fn start(command: &ServeCommand) -> Res<Self> {
        let mut builder = Command::new(&command.program);
        builder
            .args(&command.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        if command.disclaim {
            disclaim(&mut builder);
        }
        let mut child = builder.spawn()?;
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
#[allow(
    clippy::indexing_slicing,
    reason = "serde_json's Value index reads Null for a missing key or element"
)]
pub fn serve(
    hub: &Hub,
    ticket: &Ticket,
    view_only: bool,
    command: &ServeCommand,
    stop: &Arc<AtomicBool>,
) -> Ended {
    let log = &command.log_prefix;
    let mut ws = match hub.session_socket(&ticket.signal_url, &ticket.jws) {
        Ok(ws) => ws,
        Err(e) => {
            let reason = format!("signaling: {e}");
            return Ended { tell_hub: Some(failed_reason(&reason)), reason, connected: false };
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
                                            eprintln!("{log}: answer not sent: {e}");
                                        }
                                    }
                                    Err(e) => eprintln!("{log}: answer not signed: {e}"),
                                }
                            }
                        }
                        if line["connected"].as_bool() == Some(true) && !connected {
                            connected = true;
                            eprintln!(
                                "{log}: {} is {} this desktop",
                                crate::printable(&ticket.peer_name),
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
                                "{}: session {}: {}",
                                command.status_prefix,
                                crate::printable(&ticket.session_id),
                                crate::printable(message)
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
                // Before the link: the viewer learns why only from the hub. After it, the
                // helper told the viewer itself over the link (cmux.rd/1 `ended`).
                let tell_hub = (!connected).then(|| failed_reason(&reason));
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
                        crate::printable(&why)
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
                    let reason = "the viewer's offer is not signed by its device key";
                    break Ended {
                        reason: reason.into(),
                        connected,
                        tell_hub: Some(failed_reason(reason)),
                    };
                }
                if serve.is_some() {
                    continue;
                }
                let Some(offer) = RdDocument::parse(sdp) else {
                    // A WebRTC viewer (the iPhone's, or an old Mac): this host serves cmux.rd/1 only.
                    let _ = ws.send_text(r#"{"type":"bye"}"#);
                    let reason = "the viewer offered WebRTC; this host serves cmux.rd/1 viewers";
                    break Ended {
                        reason: reason.into(),
                        connected,
                        tell_hub: Some(failed_reason(reason)),
                    };
                };
                let mut started = match Serve::start(command) {
                    Ok(s) => s,
                    Err(e) => {
                        let reason = format!("the screen host could not start: {e}");
                        break Ended { tell_hub: Some(failed_reason(&reason)), reason, connected };
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

/// Starts the helper as its own responsible process in its own session (macOS).
#[cfg(target_os = "macos")]
fn disclaim(builder: &mut Command) {
    builder.disclaim_responsibility().new_session();
}

/// Elsewhere a helper has no responsible process to disclaim.
#[cfg(not(target_os = "macos"))]
fn disclaim(_: &mut Command) {}

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
    fn viewer_tickets_are_read_for_the_viewer_role_only() {
        assert!(Ticket::from_push_as(&push("viewer", "s1", "KEY"), "viewer").is_ok());
        assert!(Ticket::from_push_as(&push("host", "s1", "KEY"), "viewer").is_err());
        assert!(Ticket::from_push_as(&push("viewer", "s1", "OTHER"), "viewer").is_err());
    }

    #[test]
    fn a_failed_end_says_why_within_the_hubs_limit() {
        assert_eq!(failed_reason(""), "failed");
        assert_eq!(failed_reason("  "), "failed");
        assert_eq!(failed_reason("the screen host stopped"), "failed: the screen host stopped");
        // cmux-rd's own `failed: <error>` is not doubled; newlines and escapes go.
        assert_eq!(
            failed_reason("failed: capture: no display\n\u{1b}[31mred"),
            "failed: capture: no display red"
        );
        let long = failed_reason(&"é".repeat(300));
        assert!(long.encode_utf16().count() <= HUB_REASON_MAX, "{long}");
        assert!(long.starts_with("failed: é"));
        // A character of two UTF-16 units is never cut in half.
        let wide = failed_reason(&"😀".repeat(100));
        assert!(wide.encode_utf16().count() <= HUB_REASON_MAX);
        assert!(wide.ends_with('😀'));
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

    #[test]
    fn the_helper_is_the_command_given_and_hears_the_setup_line() {
        // A helper that answers its first line back as `{"echo": ..}`, then waits for the end
        // of its input, as `cmux-rd serve` waits for `stop`.
        let script = r#"read -r line; printf '{"echo":%s}\n' "$line"; cat >/dev/null"#;
        for disclaim in [false, true] {
            let command = ServeCommand {
                program: "/bin/sh".into(),
                args: vec!["-c".into(), script.into()],
                disclaim,
                log_prefix: "share-host".into(),
                status_prefix: "share-host".into(),
            };
            let mut serve = Serve::start(&command).unwrap();
            serve.send(&json!({ "session": "s1" }));
            let line = serve.lines.recv_timeout(Duration::from_secs(10)).unwrap();
            assert_eq!(line, json!({ "echo": { "session": "s1" } }));
            let started = std::time::Instant::now();
            serve.stop();
            // It ended at its end of input, well before the 3 s kill.
            assert!(started.elapsed() < Duration::from_secs(3));
        }
    }
}
