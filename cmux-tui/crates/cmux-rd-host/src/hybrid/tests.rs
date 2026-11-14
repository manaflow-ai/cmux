use super::*;
use crate::carrier::{Carrier, Incoming, SocketCarrier};
use crate::wire::{
    write_control, Control, DatagramOut, FrameReader, FRAME_CONTROL, FRAME_DATAGRAM,
};
use cmux_rd_link::net::{Candidate, Net, NetConfig, NetEvent};
use cmux_rd_link::{EndpointEvent, Event, KeyPair, Role};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

/// The viewer's end of the stream: reads frames, writes controls.
struct Viewer {
    stream: UnixStream,
    reader: FrameReader,
}

impl Viewer {
    fn frames(&mut self) -> Vec<(u8, Vec<u8>)> {
        let _ = self.reader.fill(&mut self.stream);
        let mut out = Vec::new();
        while let Ok(Some(f)) = self.reader.next() {
            out.push(f);
        }
        out
    }
}

fn controls(frames: &[(u8, Vec<u8>)]) -> Vec<Control> {
    frames
        .iter()
        .filter(|(ty, _)| *ty == FRAME_CONTROL)
        .filter_map(|(_, p)| serde_json::from_slice(p).ok())
        .collect()
}

fn pair() -> (UnixStream, Viewer) {
    let (host, viewer) = UnixStream::pair().expect("pair");
    host.set_nonblocking(true).expect("nb");
    viewer.set_nonblocking(true).expect("nb");
    (host, Viewer { stream: viewer, reader: FrameReader::default() })
}

#[test]
fn media_stays_on_the_stream_until_an_offer_and_a_bad_offer_says_why() {
    let (mut host, mut viewer) = pair();
    let mut reader = FrameReader::default();
    let stream = SocketCarrier::new(&mut host, &mut reader, None, DatagramOut::Stream);
    let mut carrier = HybridCarrier::new(stream, LinkCfg::default());
    carrier.send_datagram(b"frame").expect("send");
    let frames = viewer.frames();
    assert!(frames.iter().any(|(ty, p)| *ty == FRAME_DATAGRAM && p == b"frame"));
    write_control(
        &mut viewer.stream,
        &Control::LinkOffer { session: "s".into(), key: "zz".into(), candidates: vec![] },
    )
    .expect("offer");
    write_control(&mut viewer.stream, &Control::Stop).expect("stop");
    let mut out = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(2);
    while out.is_empty() && Instant::now() < deadline {
        carrier.receive(&mut out).expect("receive");
    }
    // The link messages are the carrier's; the session sees only the rest.
    assert!(matches!(out.as_slice(), [Incoming::Control(Control::Stop)]));
    let states = controls(&viewer.frames());
    assert!(
            states.iter().any(|c| matches!(c, Control::LinkState { up: false, reason: Some(r) } if r.contains("64 hex"))),
            "{states:?}"
        );
    assert!(!carrier.is_up());
}

/// The whole exchange on loopback: offer, answer and candidates on the stream,
/// then media on the link, and back to the stream when the viewer closes it.
#[test]
fn an_offer_moves_media_onto_the_link_and_a_close_moves_it_back() {
    let (mut host, mut viewer) = pair();
    let mut reader = FrameReader::default();
    let stream = SocketCarrier::new(&mut host, &mut reader, None, DatagramOut::Stream);
    let mut carrier = HybridCarrier::new(stream, LinkCfg::default());
    let keys = KeyPair::generate().expect("keys");
    let viewer_key = crate::serve::hex(&keys.public);
    let mut viewer_net: Option<Net> = None;
    let mut pending_keys = Some(keys);
    write_control(
        &mut viewer.stream,
        &Control::LinkOffer { session: "cloud-1".into(), key: viewer_key, candidates: vec![] },
    )
    .expect("offer");
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut got = Vec::new();
    let mut out = Vec::new();
    while Instant::now() < deadline
        && !(carrier.is_up() && got.iter().any(|d: &Vec<u8>| d == b"up"))
    {
        carrier.receive(&mut out).expect("receive");
        for item in out.drain(..) {
            if let Incoming::Datagram(d) = item {
                got.push(d);
            }
        }
        for control in controls(&viewer.frames()) {
            match control {
                Control::LinkAnswer { key } => {
                    let net = Net::start(NetConfig {
                        role: Role::Initiator,
                        session: b"cloud-1".to_vec(),
                        local: pending_keys.take().expect("one answer"),
                        expected_remote: crate::serve::unhex32(&key).expect("key"),
                        stun: Vec::new(),
                        bind: "127.0.0.1:0".parse().expect("bind"),
                        turn: Vec::new(),
                        relay_only: false,
                    })
                    .expect("viewer link");
                    viewer_net = Some(net);
                }
                Control::LinkCandidate { candidate } => {
                    let c = Candidate::from_wire(&candidate).expect("candidate");
                    // Loopback only in the test: the host binds 0.0.0.0.
                    let c =
                        Candidate { addr: SocketAddr::from(([127, 0, 0, 1], c.addr.port())), ..c };
                    viewer_net.as_ref().expect("answered first").add_remote_candidate(c);
                }
                _ => {}
            }
        }
        if let Some(net) = &viewer_net {
            for event in net.events() {
                if let NetEvent::Candidate(c) = event {
                    write_control(
                        &mut viewer.stream,
                        &Control::LinkCandidate { candidate: c.to_wire() },
                    )
                    .expect("candidate");
                }
                if let NetEvent::Endpoint(EndpointEvent::PathChanged { route: Some(_), .. }) = event
                {
                    net.send_datagram(b"up".to_vec());
                }
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(carrier.is_up(), "the link never came up");
    assert!(got.iter().any(|d| d == b"up"), "the viewer's datagram never arrived");
    // Media goes on the link now, not on the stream.
    carrier.send_datagram(b"media").expect("send");
    let net = viewer_net.take().expect("viewer link");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut on_link = false;
    while !on_link && Instant::now() < deadline {
        on_link = net.events().iter().any(|e| {
                matches!(e, NetEvent::Endpoint(EndpointEvent::Link(Event::Datagram(d))) if d == b"media")
            });
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(on_link, "media did not ride the link");
    assert!(!viewer.frames().iter().any(|(ty, _)| *ty == FRAME_DATAGRAM));
    // The viewer closes its link: media falls back to the stream.
    drop(net);
    let deadline = Instant::now() + Duration::from_secs(5);
    while carrier.is_up() && Instant::now() < deadline {
        carrier.receive(&mut out).expect("receive");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!carrier.is_up(), "still on the link after the viewer closed it");
    carrier.send_datagram(b"back").expect("send");
    assert!(viewer.frames().iter().any(|(ty, p)| *ty == FRAME_DATAGRAM && p == b"back"));
}

/// A new offer while media rides the link: the viewer hears it is back on the stream
/// before the answer.
#[test]
fn a_replacement_offer_reports_media_back_on_the_stream() {
    let (mut host, mut viewer) = pair();
    let mut reader = FrameReader::default();
    let stream = SocketCarrier::new(&mut host, &mut reader, None, DatagramOut::Stream);
    let mut carrier = HybridCarrier::new(stream, LinkCfg::default());
    carrier.force_up();
    let keys = KeyPair::generate().expect("keys");
    write_control(
        &mut viewer.stream,
        &Control::LinkOffer {
            session: "cloud-2".into(),
            key: crate::serve::hex(&keys.public),
            candidates: vec![],
        },
    )
    .expect("offer");
    let mut out = Vec::new();
    let mut seen = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(2);
    while !seen.iter().any(|c| matches!(c, Control::LinkAnswer { .. })) && Instant::now() < deadline
    {
        carrier.receive(&mut out).expect("receive");
        seen.extend(controls(&viewer.frames()));
        std::thread::sleep(Duration::from_millis(5));
    }
    let down = seen.iter().position(|c| {
            matches!(c, Control::LinkState { up: false, reason: Some(r) } if r.contains("replaced"))
        });
    let answer = seen.iter().position(|c| matches!(c, Control::LinkAnswer { .. }));
    assert!(matches!((down, answer), (Some(d), Some(a)) if d < a), "{seen:?}");
    assert!(!carrier.is_up());
}

#[test]
fn link_stun_takes_a_list_and_refuses_a_bad_entry() {
    assert_eq!(stun_names(None).expect("none"), Vec::<String>::new());
    let list = stun_names(Some("127.0.0.1:3478, stun.example.com:3478")).expect("list");
    assert_eq!(list, vec!["127.0.0.1:3478", "stun.example.com:3478"]);
    assert!(stun_names(Some("nope")).is_err());
    assert!(stun_names(Some("host:0")).is_err());
}

#[test]
fn link_stun_resolves_only_when_asked_and_leaves_out_a_name_that_does_not_resolve() {
    let cfg = LinkCfg::new(vec!["127.0.0.1:3478".into(), "stun.invalid:3478".into()]);
    assert!(cfg.stun().is_empty(), "nothing resolves before a session asks");
    cfg.resolve_stun();
    let deadline = Instant::now() + Duration::from_secs(10);
    while cfg.stun().is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(cfg.stun(), vec!["127.0.0.1:3478".parse::<SocketAddr>().unwrap()]);
}

#[test]
fn a_session_offered_while_stun_resolves_takes_the_servers_when_they_arrive() {
    let cfg = LinkCfg::new(vec!["127.0.0.1:3478".into()]);
    let (now, later) = cfg.stun_now_or_later();
    assert!(now.is_empty() && later.is_none(), "nothing resolves before a session asks");
    *cfg.resolved.lock().unwrap() = Stun::Resolving;
    let (now, later) = cfg.stun_now_or_later();
    assert!(now.is_empty());
    let mut later = later.expect("a later list while resolving");
    assert_eq!(later(), None);
    let server: SocketAddr = "127.0.0.1:3478".parse().unwrap();
    *cfg.resolved.lock().unwrap() = Stun::Resolved(vec![server]);
    assert_eq!(later(), Some(vec![server]));
    assert_eq!(cfg.stun_now_or_later().0, vec![server]);
}
