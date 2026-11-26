//! `cmux-rd windows-serve-selftest [--scope view|control] [--duration-s 4]`: one hub session
//! on this machine with no hub. It starts `cmux-rd serve` as a child exactly as `windows-host
//! run` does (the setup line on stdin), plays the Mac viewer over a real secure link on this
//! machine's own addresses (candidates relayed through the child's stdin and stdout), says
//! hello and start, counts the media datagrams of this desktop, stops the session, and prints
//! one JSON line. Exit 1 when no media arrived or the session did not end cleanly.

use super::hex;
use crate::args::Opts;
use crate::Res;
use cmux_process::{Command, Stdio};
use cmux_rd_link::net::{Candidate, CandidateKind, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use cmux_rd_proto::control::Control;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::net::SocketAddr;
use std::sync::mpsc;
use std::time::{Duration, Instant};

const SESSION: &str = "windows-serve-selftest";

pub fn run(opts: &Opts) -> Res<()> {
    let scope = opts.str_or("scope", "view");
    let mode = if scope == "control" { "control" } else { "view" };
    let duration = Duration::from_secs(opts.num_or("duration-s", 4u64)?.clamp(1, 30));
    let viewer = KeyPair::generate()?;
    let mut child = Command::new(std::env::current_exe()?)
        .arg("serve")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let (tx, lines) = mpsc::channel::<Value>();
    // Ends with the child: its stdout closes when the child exits (waited or killed below).
    std::thread::Builder::new().name("rd-selftest-out".into()).spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let Ok(line) = line else { break };
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                if tx.send(value).is_err() {
                    break;
                }
            }
        }
    })?;
    let mut send = |value: Value| -> Res<()> {
        writeln!(stdin, "{value}")?;
        stdin.flush()?;
        Ok(())
    };
    send(json!({
        "session": SESSION, "peer_key": hex(&viewer.public),
        "viewer": {"user": "selftest", "install": "selftest"}, "scope": scope,
        "stun": [], "turn": [], "display": "main", "max_fps": 30,
    }))?;
    let started = Instant::now();
    let deadline = started + Duration::from_secs(30) + duration;
    let mut report = json!({"scope": scope});
    let mut viewer_net: Option<Net> = None;
    let mut pending_host: Vec<Candidate> = Vec::new();
    let (mut welcome, mut first_media_ms, mut datagrams, mut bytes) = (None, None, 0u64, 0u64);
    let mut stop_at: Option<Instant> = None;
    let mut ended: Option<String> = None;
    while Instant::now() < deadline && ended.is_none() {
        // The host's lines.
        while let Ok(line) = lines.try_recv() {
            if let Some(displays) = line.get("displays") {
                report["displays"] = displays.clone();
            }
            if let Some(key) = line["key"].as_str() {
                let host = super::unhex32(key).ok_or("the host's key is not 64 hex")?;
                let net = Net::start(NetConfig {
                    role: Role::Initiator,
                    session: SESSION.as_bytes().to_vec(),
                    local: viewer.clone(),
                    expected_remote: host,
                    stun: Vec::new(),
                    bind: "0.0.0.0:0".parse()?,
                    turn: Vec::new(),
                    relay_only: false,
                })?;
                // This machine's loopback too, so the session runs on a machine with no LAN.
                let port = net.local_addr().port();
                send(json!({"candidate": format!("host 127.0.0.1:{port}")}))?;
                for c in pending_host.drain(..) {
                    net.add_remote_candidate(c);
                }
                viewer_net = Some(net);
            }
            if let Some(c) = line["candidate"].as_str().and_then(Candidate::from_wire) {
                let loopback = Candidate {
                    kind: CandidateKind::Host,
                    addr: SocketAddr::new([127, 0, 0, 1].into(), c.addr.port()),
                };
                for c in [c, loopback] {
                    match viewer_net.as_ref() {
                        Some(net) => net.add_remote_candidate(c),
                        None => pending_host.push(c),
                    }
                }
            }
            if let Some(reason) = line["ended"].as_str() {
                ended = Some(reason.to_owned());
            }
        }
        let Some(net) = viewer_net.as_ref() else {
            std::thread::sleep(Duration::from_millis(10));
            continue;
        };
        for event in net.events() {
            match event {
                NetEvent::Candidate(c) => send(json!({"candidate": c.to_wire()}))?,
                NetEvent::Endpoint(EndpointEvent::Link(Event::Established)) => {
                    report["connected_ms"] = json!(started.elapsed().as_millis() as u64);
                    let hello = Control::Hello {
                        user: "selftest".into(),
                        install: "selftest".into(),
                        class: "user".into(),
                        interactive: true,
                        udp_port: None,
                        max_datagram: 1200,
                        token: None,
                        service: "desktop".into(),
                        caps: Vec::new(),
                    };
                    let start = Control::Start { key: "selftest".into(), mode: mode.into() };
                    net.send_control(serde_json::to_vec(&hello)?);
                    net.send_control(serde_json::to_vec(&start)?);
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Control(record))) => {
                    match serde_json::from_slice::<Control>(&record) {
                        Ok(Control::Welcome { encoder, width, height, carrier, .. }) => {
                            welcome = Some(json!({"encoder": encoder, "width": width,
                                "height": height, "carrier": carrier}));
                        }
                        Ok(Control::Refused { reason }) => {
                            report["refused"] = json!(reason);
                            stop_at = Some(Instant::now());
                        }
                        _ => {}
                    }
                }
                NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) => {
                    datagrams += 1;
                    bytes += d.len() as u64;
                    if first_media_ms.is_none() {
                        first_media_ms = Some(started.elapsed().as_millis() as u64);
                        stop_at = Some(Instant::now() + duration);
                    }
                }
                NetEvent::Failed(reason) => report["link_failed"] = json!(reason),
                _ => {}
            }
        }
        if stop_at.is_some_and(|at| Instant::now() >= at) {
            // The viewer's stop, as the Mac sends it; the host answers with `ended`.
            net.send_control(serde_json::to_vec(&Control::Stop)?);
            stop_at = None;
        }
        net.wait(Some(Duration::from_millis(20)));
    }
    drop(viewer_net);
    let exited = child.wait_timeout(Duration::from_secs(5))?;
    if exited.is_none() {
        // Our own child, by its handle.
        let _ = child.kill();
        let _ = child.wait();
    }
    let ok = first_media_ms.is_some() && welcome.is_some() && ended.is_some();
    report["ok"] = json!(ok);
    report["welcome"] = welcome.unwrap_or(Value::Null);
    report["first_media_ms"] = json!(first_media_ms);
    report["datagrams"] = json!(datagrams);
    report["bytes"] = json!(bytes);
    report["ended"] = json!(ended);
    report["exited"] = json!(exited.is_some());
    println!("{report}");
    if ok {
        Ok(())
    } else {
        Err("the serve selftest saw no media or no clean end".into())
    }
}
