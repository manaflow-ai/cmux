use super::*;
use cmux_rd_proto::control::Control;
use std::time::{Duration, Instant};

/// Every interface: the link's host routes are this machine's non-loopback addresses.
fn bind() -> SocketAddr {
    "0.0.0.0:0".parse().unwrap()
}

fn hello() -> Vec<u8> {
    serde_json::to_vec(&json!({
        "t": "hello", "user": "u", "install": "i", "class": "user", "interactive": true,
        "udp_port": null, "max_datagram": 1200, "service": "desktop", "caps": ["tile"],
        "future_field": 7
    }))
    .unwrap()
}

fn controls(out: &[Out], host: bool) -> Vec<(u8, Value)> {
    let mut frames = Frames::default();
    for item in out {
        match item {
            Out::Host(bytes) if host => frames.push(bytes),
            Out::Viewer(bytes) if !host => frames.push(bytes),
            _ => {}
        }
    }
    let mut parsed = Vec::new();
    while let Some((ty, payload)) = frames.next().unwrap() {
        parsed.push((ty, serde_json::from_slice(&payload).unwrap_or(Value::Null)));
    }
    parsed
}

fn viewer_frames(out: &[Out]) -> Vec<(u8, Vec<u8>)> {
    let mut frames = Frames::default();
    for item in out {
        if let Out::Viewer(bytes) = item {
            frames.push(bytes);
        }
    }
    let mut parsed = Vec::new();
    while let Some(f) = frames.next().unwrap() {
        parsed.push(f);
    }
    parsed
}

fn welcome(caps: &[&str]) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "t": "welcome", "encoder": "openh264", "width": 1280, "height": 800,
        "max_datagram": 1126, "carrier": "stream", "service": "desktop", "caps": caps
    }))
    .unwrap()
}

fn started() -> Vec<u8> {
    serde_json::to_vec(&json!({"t": "started", "session": 1})).unwrap()
}

#[test]
fn without_the_platforms_word_the_splice_changes_no_byte() {
    let mut splice = Splice::new(None, bind());
    let mut out = Vec::new();
    splice.on_viewer(FRAME_CONTROL, hello(), &mut out);
    splice.on_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
    splice.on_host(FRAME_CONTROL, welcome(&["tile"]), &mut out);
    splice.on_host(FRAME_CONTROL, started(), &mut out);
    assert_eq!(
        out,
        vec![
            Out::Host(frame(FRAME_CONTROL, &hello())),
            Out::Host(frame(FRAME_DATAGRAM, b"input")),
            Out::Viewer(frame(FRAME_CONTROL, &welcome(&["tile"]))),
            Out::Viewer(frame(FRAME_CONTROL, &started())),
        ]
    );
}

#[test]
fn the_hello_gains_the_cap_and_keeps_every_other_field() {
    let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new(), Vec::new()).unwrap()), bind());
    let mut out = Vec::new();
    splice.on_viewer(FRAME_CONTROL, hello(), &mut out);
    let sent = controls(&out, true);
    assert_eq!(sent.len(), 1);
    let hello = &sent[0].1;
    assert_eq!(hello["future_field"], 7);
    assert_eq!(hello["caps"], json!(["tile", "link.udp"]));
    // The rd host's own parser reads it.
    let parsed: Control = serde_json::from_value(hello.clone()).unwrap();
    assert!(matches!(parsed, Control::Hello { caps, .. } if caps.contains(&LINK_CAP.to_owned())));
}

#[test]
fn a_host_without_the_cap_keeps_every_datagram_on_the_stream() {
    let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new(), Vec::new()).unwrap()), bind());
    let mut out = Vec::new();
    splice.on_viewer(FRAME_CONTROL, hello(), &mut out);
    out.clear();
    splice.on_host(FRAME_CONTROL, welcome(&["tile"]), &mut out);
    splice.on_host(FRAME_CONTROL, started(), &mut out);
    assert!(out.contains(&Out::Note("not_answered".into())));
    assert!(controls(&out, true).is_empty(), "no offer: {out:?}");
    assert!(splice.link.is_none());
    out.clear();
    splice.on_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
    assert_eq!(out, vec![Out::Host(frame(FRAME_DATAGRAM, b"input"))]);
}

#[test]
fn the_offer_waits_for_started_and_the_link_carries_datagrams_both_ways() {
    let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new(), Vec::new()).unwrap()), bind());
    let mut out = Vec::new();
    splice.on_viewer(FRAME_CONTROL, hello(), &mut out);
    out.clear();
    splice.on_host(FRAME_CONTROL, welcome(&["tile", "link.udp"]), &mut out);
    // The viewer sees the caps it asked for, and nothing goes to the host yet:
    // the host reads `start` next.
    let seen = controls(&out, false);
    assert_eq!(seen[0].1["caps"], json!(["tile"]));
    assert!(controls(&out, true).is_empty());
    out.clear();
    splice.on_host(FRAME_CONTROL, started(), &mut out);
    let offer = controls(&out, true);
    assert_eq!(offer.len(), 1);
    let Ok(Control::LinkOffer { session, key, .. }) = serde_json::from_value(offer[0].1.clone())
    else {
        panic!("not a link_offer the host parses: {:?}", offer[0].1);
    };
    assert_eq!(viewer_frames(&out), vec![(FRAME_CONTROL, started())]);
    // The host's side, as hybrid.rs answers.
    let (mut host, host_key) = DatagramLink::respond(&session, &key, bind()).unwrap();
    out.clear();
    let answer = serde_json::to_vec(&Control::LinkAnswer { key: host_key }).unwrap();
    splice.on_host(FRAME_CONTROL, answer, &mut out);
    let state = serde_json::to_vec(&Control::LinkState { up: true, reason: None }).unwrap();
    splice.on_host(FRAME_CONTROL, state, &mut out);
    assert!(viewer_frames(&out).is_empty(), "link controls never reach the viewer: {out:?}");
    // Bring the link up, candidates crossing as the stream would carry them.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut pending = out;
    while Instant::now() < deadline
        && !(host.is_up() && splice.link.as_ref().is_some_and(DatagramLink::is_up))
    {
        for (ty, c) in controls(&pending, true) {
            if ty == FRAME_CONTROL && c["t"] == "link_candidate" {
                host.add_remote_candidate(c["candidate"].as_str().unwrap());
            }
        }
        pending = Vec::new();
        splice.poll(&mut pending);
        let mut host_out = Vec::new();
        host.poll(&mut host_out);
        for item in host_out {
            if let LinkOut::Candidate(c) = item {
                let msg = serde_json::to_vec(&Control::LinkCandidate { candidate: c }).unwrap();
                let mut ignored = Vec::new();
                splice.on_host(FRAME_CONTROL, msg, &mut ignored);
                assert!(
                    viewer_frames(&ignored).is_empty(),
                    "link_candidate never reaches the viewer"
                );
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(host.is_up(), "host side up");
    // Viewer datagrams now take the link, not the stream.
    let mut out = Vec::new();
    splice.on_viewer(FRAME_DATAGRAM, b"input".to_vec(), &mut out);
    assert!(controls(&out, true).is_empty(), "nothing on the stream: {out:?}");
    host.send_datagram(b"frame");
    let deadline = Instant::now() + Duration::from_secs(5);
    let (mut got_input, mut got_frame) = (false, false);
    while Instant::now() < deadline && !(got_input && got_frame) {
        let mut produced = Vec::new();
        host.poll(&mut produced);
        got_input |= produced.contains(&LinkOut::Datagram(b"input".to_vec()));
        let mut out = Vec::new();
        splice.poll(&mut out);
        got_frame |= viewer_frames(&out).contains(&(FRAME_DATAGRAM, b"frame".to_vec()));
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(got_input && got_frame, "input {got_input} frame {got_frame}");
}

#[test]
fn a_viewer_that_asks_for_the_cap_itself_is_left_alone() {
    let mut splice = Splice::new(Some(ViewerOffer::new(Vec::new(), Vec::new()).unwrap()), bind());
    let own = serde_json::to_vec(&json!({"t": "hello", "caps": ["link.udp"]})).unwrap();
    let mut out = Vec::new();
    splice.on_viewer(FRAME_CONTROL, own.clone(), &mut out);
    splice.on_host(FRAME_CONTROL, welcome(&["link.udp"]), &mut out);
    assert_eq!(
        out,
        vec![
            Out::Host(frame(FRAME_CONTROL, &own)),
            Out::Viewer(frame(FRAME_CONTROL, &welcome(&["link.udp"]))),
        ]
    );
}

/// A carrier stream the test plays the host on.
struct FakeRemote {
    incoming: tokio::sync::Mutex<mpsc::UnboundedReceiver<Bytes>>,
    sent: mpsc::UnboundedSender<Vec<u8>>,
}

impl Remote for FakeRemote {
    async fn send(&self, bytes: Bytes) -> Result<(), BridgeError> {
        let _ = self.sent.send(bytes.to_vec());
        Ok(())
    }

    async fn receive(&self) -> Result<Option<(Bytes, bool)>, BridgeError> {
        Ok(self.incoming.lock().await.recv().await.map(|bytes| (bytes, false)))
    }

    async fn close(&self) -> Result<(), BridgeError> {
        Ok(())
    }

    async fn failure(&self) -> BridgeError {
        std::future::pending().await
    }
}

#[tokio::test]
async fn a_viewer_that_stops_reading_still_gets_its_feedback_to_the_host() {
    let (host, incoming) = mpsc::unbounded_channel();
    let (sent, mut reached_host) = mpsc::unbounded_channel();
    let remote = Arc::new(FakeRemote { incoming: tokio::sync::Mutex::new(incoming), sent });
    // A stdout nobody reads: it holds 1 KiB, then every write waits.
    let (stdout, _unread) = tokio::io::duplex(1024);
    let (mut viewer, stdin) = tokio::io::duplex(64 * 1024);
    // Far more video than stdout holds.
    for _ in 0..64 {
        host.send(Bytes::from(frame(FRAME_DATAGRAM, &[7; 1000]))).unwrap();
    }
    let feedback = frame(FRAME_DATAGRAM, b"feedback");
    let viewer_side = async {
        tokio::task::yield_now().await;
        viewer.write_all(&feedback).await.unwrap();
        tokio::time::timeout(Duration::from_secs(5), reached_host.recv()).await
    };
    tokio::select! {
        ended = bridge(remote, stdin, stdout, Vec::new(), Vec::new(), |_| {}) => panic!("bridge ended: {ended:?}"),
        got = viewer_side => {
            assert_eq!(got.expect("feedback held behind stdout"), Some(feedback.clone()));
        }
    }
}
