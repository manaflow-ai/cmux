//! `cmux-rd view`: view and control another of your devices (a Mac today) from Linux, through
//! the device hub, the way the Mac app's viewer does (docs/device-hub/PROTOCOL.md, Session
//! flow; the Mac's `MacScreenHubViewer` and `MacScreenSession`):
//!
//!   cmux-rd view [DEVICE] [--scope full|view] [--hub URL] [--display :0]
//!                [--stack-token-file PATH|-] [--max-fps N] [--stats-file PATH] [--list]
//!
//! 1. Signs in to the account (a kept Stack refresh token, else a browser link) and registers
//!    this machine as a `linux` viewer device with its own key (`cmux/screen-viewer/`, apart
//!    from `linux-host`'s, because the hub keeps one socket per device).
//! 2. Picks DEVICE (a name or an id prefix; with none, the only shared device online; a whole
//!    device id this account does not list goes to the hub, which refuses another account's) and asks
//!    for a session (`POST /v1/sessions`); the host's person allows it unless they already did.
//! 3. Takes the viewer ticket from the user socket, opens the session's signaling socket, sends a
//!    signed cmux.rd/1 offer, checks the host's signed answer, and opens the secure link in this
//!    process (no `connect` child: one hop, design D7).
//! 4. Shows the stream in an X11 window and sends the window's keyboard, pointer and scroll to
//!    the host's input path (stream.rs, window.rs).
//!
//! The decoder is Cisco's OpenH264 binary, downloaded from Cisco on first use (Cisco's patent
//! license covers only that binary); it decodes Constrained Baseline, so the hello offers the
//! `h264.baseline` cap and the host encodes that profile for this session.

mod stream;
mod window;

use crate::args::Opts;
use crate::linux_host::{stack_login, with_fresh_identity, DEFAULT_HUB};
use crate::Res;
use cmux_hub_host::hub::{Hub, HubError};
use cmux_hub_host::identity::{self, Account, Device};
use cmux_hub_host::net::{Message, WebSocket};
use cmux_hub_host::rd_doc::{self, RdDocument};
use cmux_hub_host::session::{close_ends_session, Ticket};
use cmux_hub_host::{b64, printable};
use cmux_rd_link::net::{Candidate, NetConfig};
use cmux_rd_link::{KeyPair, Role};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const USAGE: &str = "usage: cmux-rd view [DEVICE] [--scope full|view] [--hub URL] [--display :0] [--stack-token-file PATH|-] [--max-fps N] [--stats-file PATH] [--list]";

/// How long a request may wait for the host's person (the hub expires it after 5 min).
const APPROVAL_WITHIN: Duration = Duration::from_secs(5 * 60 + 10);
/// How long the host has to answer the offer once both sides are on the signaling socket.
const ANSWER_WITHIN: Duration = Duration::from_secs(30);
const PING_EVERY: Duration = Duration::from_secs(30);

pub fn run_cli(args: &[String]) -> i32 {
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("{USAGE}");
        return 0;
    }
    let (device, rest) = match args.first() {
        Some(first) if !first.starts_with("--") => (Some(first.clone()), &args[1..]),
        _ => (None, args),
    };
    // `--list` takes no value.
    let mut list = false;
    let rest: Vec<String> = rest
        .iter()
        .filter(|a| {
            let flag = a.as_str() == "--list";
            list |= flag;
            !flag
        })
        .cloned()
        .collect();
    let opts = match Opts::parse(&rest) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("{e}\n{USAGE}");
            return 2;
        }
    };
    let scope = opts.str_or("scope", "full");
    if scope != "full" && scope != "view" {
        eprintln!("--scope takes full or view\n{USAGE}");
        return 2;
    }
    match run(device.as_deref(), &scope, list, &opts) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("cmux-rd view: {e}");
            1
        }
    }
}

/// This viewer's own device directory, beside `linux-host`'s (`cmux/screen-host`).
fn viewer_dir() -> Res<PathBuf> {
    let host = identity::config_dir()?;
    Ok(host.parent().map_or_else(|| host.join("viewer"), |p| p.join("screen-viewer")))
}

fn run(target: Option<&str>, scope: &str, list: bool, opts: &Opts) -> Res<()> {
    let dir = viewer_dir()?;
    identity::private_dir(&dir)?;
    let hub_url = match opts.get("hub") {
        Some(url) => url.to_owned(),
        None => Account::load(&dir)?.map_or_else(|| DEFAULT_HUB.to_owned(), |a| a.hub),
    };
    let token = access_token(&dir, opts.get("stack-token-file"))?;
    // Cisco's decoder first: its one-time download must not run while a host waits.
    let decoder = if list { None } else { Some(stream::open_decoder()?) };
    let device = match Device::load(&dir)? {
        Some(d) => d,
        None => Device::generate(&identity::host_name())?,
    };
    let (_, (hub, user_id)) = with_fresh_identity(device, |device| {
        device.save(&dir)?;
        let hub = Hub::new(&hub_url, device.clone(), None)?;
        let user_id = hub.sign_in_with_stack(&token)?;
        hub.register("linux")?;
        Ok((hub, user_id))
    })?;
    Account { hub: hub_url.clone(), user_id, anchored_until: 0 }.save(&dir)?;

    let devices = hub.call("GET", "/v1/devices", None)?;
    let candidates = shared_devices(&devices, &hub.device.id);
    if list {
        if candidates.is_empty() {
            println!("No other device of this account shares its screen.");
        }
        for d in &candidates {
            println!(
                "{}  {}  {}{}",
                d.id,
                d.platform,
                printable(&d.name),
                if d.online { "" } else { "  (offline)" }
            );
        }
        return Ok(());
    }
    let host = pick(&candidates, target)?;

    // The ticket comes on the user socket, possibly before the request's own answer.
    let mut user = hub.user_socket()?;
    let request = hub
        .call("POST", "/v1/sessions", Some(&json!({ "hostId": host.id, "scope": scope })))
        .map_err(|e| explain_request(e, &host.name))?;
    let session_id = request["session"]["id"].as_str().ok_or("no session id")?.to_owned();
    if request["session"]["state"].as_str() == Some("pending") {
        eprintln!(
            "Asked {} to {} it. Waiting for its person to allow this...",
            printable(&host.name),
            if scope == "full" { "control" } else { "view" }
        );
    }
    let ticket = match wait_for_ticket(&mut user, &session_id) {
        Ok(t) => t,
        Err(e) => {
            let _ = hub.end(&session_id, "viewer_disconnected");
            return Err(e);
        }
    };
    let decoder = decoder.ok_or("no decoder")?;
    let result = view_session(&hub, &mut user, &ticket, &host, scope, opts, decoder);
    let reason = match &result {
        Ok(o) if o.connected => "viewer_disconnected",
        _ => "failed",
    };
    let _ = hub.end(&session_id, reason);
    user.close();
    let outcome = result?;
    eprintln!("Session ended: {}", printable(&outcome.reason));
    Ok(())
}

/// The account access token: `--stack-token-file`, the kept refresh token, or a browser sign-in
/// whose refresh token is kept (0600, this user's) for the next run.
fn access_token(dir: &Path, token_file: Option<&str>) -> Res<String> {
    if token_file.is_some() {
        return stack_login::access_token(token_file);
    }
    let kept = dir.join("stack-refresh-token");
    if let Some(bytes) = identity::read_private(&kept)? {
        let refresh = String::from_utf8_lossy(&bytes).trim().to_owned();
        match stack_login::refresh(stack_login::CONFIG_URL, &refresh) {
            Ok(access) => return Ok(access),
            Err(e) => {
                eprintln!("cmux-rd view: the kept sign-in no longer works ({e}); signing in again")
            }
        }
    }
    let (access, refresh) = stack_login::sign_in_keeping_refresh(
        stack_login::CONFIG_URL,
        stack_login::POLL_EVERY,
        stack_login::LOGIN_WITHIN,
        stack_login::announce,
    )?;
    identity::write_private(&kept, refresh.as_bytes())?;
    Ok(access)
}

#[derive(Debug, Clone, PartialEq)]
struct HostDevice {
    id: String,
    name: String,
    platform: String,
    online: bool,
}

/// The account's other devices that share their screen, online first.
fn shared_devices(answer: &Value, own_id: &str) -> Vec<HostDevice> {
    let truthy = |v: &Value| v.as_bool().unwrap_or(false) || v.as_u64().is_some_and(|n| n != 0);
    let mut out: Vec<HostDevice> = answer["devices"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|d| {
            d["id"].as_str().is_some_and(|id| id != own_id) && truthy(&d["macScreenShared"])
        })
        .map(|d| HostDevice {
            id: d["id"].as_str().unwrap_or_default().to_owned(),
            name: d["name"].as_str().unwrap_or_default().to_owned(),
            platform: d["platform"].as_str().unwrap_or_default().to_owned(),
            online: truthy(&d["online"]),
        })
        .collect();
    out.sort_by_key(|d| !d.online);
    out
}

/// The device named `target` (an exact id, an id prefix, or a name, any case), or with none the
/// one shared device online.
fn pick(devices: &[HostDevice], target: Option<&str>) -> Res<HostDevice> {
    let names = || {
        devices
            .iter()
            .map(|d| format!("{} ({})", printable(&d.name), &d.id[..d.id.len().min(8)]))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let Some(target) = target else {
        let online: Vec<&HostDevice> = devices.iter().filter(|d| d.online).collect();
        return match online.as_slice() {
            [one] => Ok((*one).clone()),
            [] => Err("no device of this account is online and sharing its screen".into()),
            _ => Err(format!("several devices share their screen; name one: {}", names()).into()),
        };
    };
    let lower = target.to_lowercase();
    let matches: Vec<&HostDevice> = devices
        .iter()
        .filter(|d| d.id == target)
        .chain(devices.iter().filter(|d| d.id != target && d.id.starts_with(&lower)))
        .chain(devices.iter().filter(|d| d.name.to_lowercase() == lower))
        .collect();
    let mut unique: Vec<&HostDevice> = Vec::new();
    for d in matches {
        if !unique.iter().any(|u| u.id == d.id) {
            unique.push(d);
        }
    }
    match unique.as_slice() {
        [one] => Ok((*one).clone()),
        // A whole device id this account does not list is asked of the hub all the same: the hub
        // decides who may view a device (another account's is refused there, not here).
        [] if device_id_shaped(target) => Ok(HostDevice {
            id: target.to_owned(),
            name: target.to_owned(),
            platform: "unknown".into(),
            online: false,
        }),
        [] => {
            Err(format!("no shared device is called {}; shared: {}", printable(target), names())
                .into())
        }
        _ => Err(format!("{} names several devices: {}", printable(target), names()).into()),
    }
}

fn explain_request(
    e: Box<dyn std::error::Error + Send + Sync>,
    host: &str,
) -> Box<dyn std::error::Error + Send + Sync> {
    let Some(h) = e.downcast_ref::<HubError>() else { return e };
    let host = printable(host);
    match h.code.as_str() {
        "host_offline" => format!("{host} is offline").into(),
        "not_shared" => format!("{host} does not share its screen").into(),
        "permission_none" => format!("{host} does not let this device in").into(),
        "not_found" => {
            format!("{host} is no device of this account (device hub {} not_found)", h.status)
                .into()
        }
        _ => e,
    }
}

/// A whole device id as the hub makes them (a UUID: 8-4-4-4-12 hex digits).
fn device_id_shaped(text: &str) -> bool {
    let groups: Vec<&str> = text.split('-').collect();
    groups.len() == 5
        && groups
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(g, n)| g.len() == n && g.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// Reads the user socket until the viewer ticket for `session_id` (or the request's end).
fn wait_for_ticket(user: &mut WebSocket, session_id: &str) -> Res<Ticket> {
    let deadline = Instant::now() + APPROVAL_WITHIN;
    let mut last_ping = Instant::now();
    while Instant::now() < deadline {
        if last_ping.elapsed() >= PING_EVERY {
            user.send_text(r#"{"type":"ping"}"#)?;
            last_ping = Instant::now();
        }
        let push = match user.recv(Duration::from_millis(500))? {
            None => continue,
            Some(Message::Closed(code, why)) => {
                return Err(format!(
                    "the hub closed this device's socket ({code} {})",
                    printable(&why)
                )
                .into())
            }
            Some(Message::Text(text)) => match serde_json::from_str::<Value>(&text) {
                Ok(v) => v,
                Err(_) => continue,
            },
        };
        if push["sessionId"].as_str() != Some(session_id) {
            continue;
        }
        match push["type"].as_str() {
            Some("session.ticket") => return Ticket::from_push_as(&push, "viewer"),
            Some("session.denied") => return Err("the host's person denied the request".into()),
            Some("session.revoked" | "session.ended") => {
                return Err(format!(
                    "the request ended: {}",
                    printable(push["reason"].as_str().unwrap_or("no reason"))
                )
                .into())
            }
            _ => {}
        }
    }
    Err("nobody allowed the request within 5 minutes".into())
}

struct Outcome {
    reason: String,
    connected: bool,
}

/// What the hub thread tells the stream loop.
pub(crate) enum FromHub {
    Candidate(Candidate),
    End(String),
}

/// What the stream loop tells the hub thread.
pub(crate) enum ToHub {
    Candidate(String),
    Path(&'static str),
}

/// Signals one session and runs it: offer, answer, the link, then the window until it ends.
fn view_session(
    hub: &Hub,
    user: &mut WebSocket,
    ticket: &Ticket,
    host: &HostDevice,
    scope: &str,
    opts: &Opts,
    decoder: cmux_encode::openh264::OpenH264Decoder,
) -> Res<Outcome> {
    let mut signal = hub.session_socket(&ticket.signal_url, &ticket.jws)?;
    let keys = KeyPair::generate()?;
    let display = opts.str_or("display", &std::env::var("DISPLAY").unwrap_or_else(|_| ":0".into()));
    let screen = window::screen_size(&display)?;
    let offer = RdDocument {
        key: hex(&keys.public),
        // The stream fits this screen: the host scales down to it, so the window shows it 1:1.
        max_width: Some(screen.0),
        max_fps: Some(opts.num_or("max-fps", 60u32)?),
        // `--encode-profile ultra` asks the host for the ultra profile (standard when absent).
        encode_profile: opts
            .get("encode-profile")
            .map(|_| opts.encode_profile())
            .transpose()?
            .map(|p| p.as_str().to_owned()),
        ..RdDocument::default()
    };
    signal.send_text(&signed_frame("offer", &offer.text(), &ticket.session_id, hub)?)?;
    let answer = wait_for_answer(&mut signal, user, ticket)?;
    let peer = unhex32(&answer.key).ok_or("the host's session key is malformed")?;
    let (stun, turn) = rd_doc::servers(&ticket.ice);
    let (stun, stun_later) = crate::carrier::stun_servers(&stun, false);
    let turn: Vec<crate::carrier::TurnSetup> = turn
        .into_iter()
        .map(|t| crate::carrier::TurnSetup {
            addr: t.addr,
            username: t.username,
            password: t.password,
        })
        .collect();
    let net = cmux_rd_link::net::Net::start(NetConfig {
        role: Role::Initiator,
        session: ticket.session_id.clone().into_bytes(),
        local: keys,
        expected_remote: peer,
        stun,
        bind: "0.0.0.0:0".parse()?,
        turn: crate::carrier::turn_servers(&turn),
        relay_only: false,
    })?;
    if let Some(later) = stun_later {
        net.add_stun_later(later);
    }
    // A host that dies without a close ends this viewer instead of freezing it.
    net.set_peer_lost(Some(std::time::Duration::from_micros(cmux_rd_link::PEER_LOST_US)));
    for c in answer.candidates.iter().filter_map(|c| Candidate::from_wire(c)) {
        net.add_remote_candidate(c);
    }
    eprintln!(
        "Connecting to {} ({})...",
        printable(&host.name),
        if scope == "full" { "control" } else { "view only" }
    );

    // The hub side runs on its own thread: the user socket's pings and pushes, the signaling
    // socket's candidates, and the stream's candidates and path going out.
    let (to_stream, from_hub) = mpsc::channel::<FromHub>();
    let (to_hub, from_stream) = mpsc::channel::<ToHub>();
    let waker = stream::Waker::new()?;
    let hub_waker = waker.clone();
    let session_id = ticket.session_id.clone();
    std::thread::scope(|s| -> Res<Outcome> {
        let signals = s.spawn(move || {
            hub_loop(user, &mut signal, &session_id, &to_stream, &hub_waker, &from_stream)
        });
        let config = stream::Config {
            display: display.clone(),
            title: format!("{} (cmux)", host.name),
            control: scope == "full",
            viewer_id: hub.device.id.clone(),
            stats_file: opts.get("stats-file").map(PathBuf::from),
        };
        let ended = stream::run(net, decoder, &config, &from_hub, &waker, &to_hub);
        drop(to_hub);
        let _ = signals.join();
        let ended = ended?;
        Ok(Outcome { reason: ended.reason, connected: ended.connected })
    })
}

/// Services both sockets until the stream ends (the stream closes `from_stream`).
fn hub_loop(
    user: &mut WebSocket,
    signal: &mut WebSocket,
    session_id: &str,
    to_stream: &mpsc::Sender<FromHub>,
    waker: &stream::Waker,
    from_stream: &mpsc::Receiver<ToHub>,
) {
    let mut last_ping = Instant::now();
    let (mut signaling, mut user_open) = (true, true);
    let tell = |m: FromHub| {
        let _ = to_stream.send(m);
        waker.wake();
    };
    loop {
        loop {
            match from_stream.try_recv() {
                Ok(ToHub::Candidate(c)) if signaling => {
                    let frame = json!({"type": "candidate", "candidate": c, "sdpMid": "cmux-rd", "sdpMLineIndex": 0});
                    let _ = signal.send_text(&frame.to_string());
                }
                Ok(ToHub::Path(path)) if signaling => {
                    let _ = signal.send_text(&json!({"type": "path", "path": path}).to_string());
                }
                Ok(_) => {}
                Err(mpsc::TryRecvError::Empty) => break,
                Err(mpsc::TryRecvError::Disconnected) => {
                    if signaling {
                        let _ = signal.send_text(r#"{"type":"bye"}"#);
                        signal.close();
                    }
                    return;
                }
            }
        }
        if user_open && last_ping.elapsed() >= PING_EVERY {
            user_open = user.send_text(r#"{"type":"ping"}"#).is_ok();
            last_ping = Instant::now();
        }
        if user_open {
            match user.recv(Duration::from_millis(if signaling { 50 } else { 100 })) {
                Ok(Some(Message::Text(text))) => {
                    if let Ok(push) = serde_json::from_str::<Value>(&text) {
                        if push["sessionId"].as_str() == Some(session_id)
                            && matches!(
                                push["type"].as_str(),
                                Some("session.revoked" | "session.ended")
                            )
                        {
                            tell(FromHub::End(format!(
                                "the hub ended the session ({})",
                                printable(push["reason"].as_str().unwrap_or("no reason"))
                            )));
                        }
                    }
                }
                Ok(Some(Message::Closed(code, _))) if code == 4001 || code == 4003 => {
                    tell(FromHub::End("this device was removed or signed out".into()));
                    user_open = false;
                }
                Ok(Some(Message::Closed(..))) | Err(_) => user_open = false,
                Ok(None) => {}
            }
        }
        if !signaling {
            if !user_open {
                std::thread::sleep(Duration::from_millis(100));
            }
            continue;
        }
        match signal.recv(Duration::from_millis(50)) {
            Ok(Some(Message::Text(text))) => {
                let Ok(frame) = serde_json::from_str::<Value>(&text) else { continue };
                match frame["type"].as_str() {
                    Some("candidate") if frame["sdpMid"].as_str() == Some("cmux-rd") => {
                        if let Some(c) = frame["candidate"].as_str().and_then(Candidate::from_wire)
                        {
                            tell(FromHub::Candidate(c));
                        }
                    }
                    Some("bye") => tell(FromHub::End("the host said bye".into())),
                    _ => {}
                }
            }
            Ok(Some(Message::Closed(code, why))) => {
                signaling = false;
                if close_ends_session(code) {
                    tell(FromHub::End(format!(
                        "the hub closed the session ({code} {})",
                        printable(&why)
                    )));
                }
            }
            Err(_) => signaling = false,
            Ok(None) => {}
        }
    }
}

/// Waits for the host's signed answer; pings the user socket meanwhile.
fn wait_for_answer(
    signal: &mut WebSocket,
    user: &mut WebSocket,
    ticket: &Ticket,
) -> Res<RdDocument> {
    let deadline = Instant::now() + ANSWER_WITHIN;
    let mut last_ping = Instant::now();
    while Instant::now() < deadline {
        if last_ping.elapsed() >= PING_EVERY {
            user.send_text(r#"{"type":"ping"}"#)?;
            last_ping = Instant::now();
        }
        let text = match signal.recv(Duration::from_millis(500))? {
            None => continue,
            Some(Message::Closed(code, why)) => {
                return Err(format!(
                    "signaling closed before the answer ({code} {})",
                    printable(&why)
                )
                .into())
            }
            Some(Message::Text(text)) => text,
        };
        let Ok(frame) = serde_json::from_str::<Value>(&text) else { continue };
        match frame["type"].as_str() {
            Some("answer") => {
                let sdp = frame["sdp"].as_str().unwrap_or_default();
                let fp_sig = frame["fpSig"].as_str().unwrap_or_default();
                if !rd_doc::verify_fp_sig(sdp, fp_sig, &ticket.session_id, "host", &ticket.peer_key)
                {
                    let _ = signal.send_text(r#"{"type":"bye"}"#);
                    return Err("the host's answer is not signed by its device key".into());
                }
                return RdDocument::parse(sdp).ok_or_else(|| {
                    "the host answered with WebRTC, not cmux.rd/1: this viewer needs a host that offers cmux.rd/1".into()
                });
            }
            Some("bye") => return Err("the host said bye before answering".into()),
            Some("peer-left") => {
                return Err(format!(
                    "the host left signaling: {}",
                    printable(frame["reason"].as_str().unwrap_or("no reason"))
                )
                .into())
            }
            _ => {}
        }
    }
    Err("the host did not answer within 30 s".into())
}

/// `{"type": .., "sdp": .., "fpSig": ..}` signed for the viewer role.
fn signed_frame(kind: &str, sdp: &str, session: &str, hub: &Hub) -> Res<String> {
    let fingerprint = rd_doc::fingerprint_of(sdp).ok_or("no fingerprint")?;
    let sig = hub.sign(&rd_doc::fingerprint_message(session, "viewer", &fingerprint))?;
    Ok(json!({ "type": kind, "sdp": sdp, "fpSig": b64::encode(&sig) }).to_string())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex32(text: &str) -> Option<[u8; 32]> {
    let text = text.trim();
    if text.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(2 * i..2 * i + 2)?, 16).ok()?;
    }
    Some(out)
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
