//! The media lane end to end: browser video as a WebRTC video track on the
//! link's own peer connection, negotiated per side, with NACK recovery and
//! keyframe requests through webrtc-rs's interceptors.

use std::time::Duration;

use bytes::Bytes;
use cnx_link::dial::{self, SessionEvents};
use cnx_link::media::{MediaLane, OutgoingFrame, VideoIn, VideoOut};
use cnx_link::testing::{FakeOptions, FakeSignaling};
use cnx_link::{DialOptions, Link, LinkConfig, SignalingClient, TransportKind};
use tokio::sync::mpsc;

fn options(video: bool) -> DialOptions {
    DialOptions {
        include_loopback: true,
        timeout: Duration::from_secs(20),
        video_lane: video,
        ..DialOptions::default()
    }
}

/// An Annex-B access unit: SPS, PPS and an IDR slice, or one P slice.
fn access_unit(keyframe: bool, slice: usize, fill: u8) -> Bytes {
    let mut au = Vec::new();
    if keyframe {
        au.extend_from_slice(&[0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x1f, 0xda, 0x01]);
        au.extend_from_slice(&[0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80]);
        au.extend_from_slice(&[0, 0, 0, 1, 0x65]);
    } else {
        au.extend_from_slice(&[0, 0, 0, 1, 0x41]);
    }
    au.extend(std::iter::repeat_n(fill.max(2), slice));
    Bytes::from(au)
}

struct Pair {
    phone: Link,
    mac: Link,
    _server: FakeSignaling,
}

async fn pair(kind: TransportKind, phone: DialOptions, mac: DialOptions) -> Pair {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let phone_id = uuid::Uuid::new_v4().to_string();
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac_client = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    let (links_tx, mut links_rx) = mpsc::channel(1);
    tokio::spawn(async move {
        while let Some(session) = mac_client.next_session().await {
            let first = session.first;
            let events = SessionEvents {
                backend: mac_client.events(),
                session_id: first.session_id.clone(),
                session: session.events,
            };
            let connected =
                dial::answer(&mac_client, first, events, &mac, LinkConfig::default()).await.expect("answer");
            let _ = links_tx.send(connected.link).await;
        }
    });
    let phone_client =
        SignalingClient::connect(&server.base_url, "user:alice", "team", &phone_id).await.unwrap();
    let connected =
        dial::connect(&phone_client, &mac_id, kind, &phone, LinkConfig::default()).await.expect("dial");
    let mac = links_rx.recv().await.unwrap();
    Pair { phone: connected.link, mac, _server: server }
}

fn out(link: &Link) -> VideoOut {
    match link.media() {
        Some(MediaLane::Out(out)) => out,
        other => panic!("expected the Mac's sender, got {other:?}"),
    }
}

fn input(link: &Link) -> VideoIn {
    match link.media() {
        Some(MediaLane::In(input)) => input,
        other => panic!("expected the phone's receiver, got {other:?}"),
    }
}

/// Streams `n` frames at 60 fps (a keyframe every 60) and returns the
/// frames the phone decoded, with the Mac's last state.
async fn stream(pair: &Pair, n: u64) -> (Vec<cnx_link::media::ReceivedFrame>, cnx_link::media::SenderState) {
    let out = out(&pair.mac);
    let input = input(&pair.phone);
    let mut frames = input.subscribe().await;
    let mut claim = out.claim();
    let mut got = Vec::new();
    let mut ticker = tokio::time::interval(Duration::from_micros(16_667));
    let mut keyframe_next = true;
    for i in 0..n {
        ticker.tick().await;
        // The source answers keyframe requests (the receiver's PLI).
        while claim.keyframes.try_recv().is_ok() {
            keyframe_next = true;
        }
        let keyframe = keyframe_next || i % 60 == 0;
        keyframe_next = false;
        let au = access_unit(
            keyframe,
            if keyframe { 30_000 } else { 3_000 + (i as usize % 5) * 400 },
            (i % 200) as u8 + 3,
        );
        claim.send(OutgoingFrame { access_unit: au, capture_us: i * 16_667 }).await.unwrap();
        while let Ok(frame) = frames.frames.try_recv() {
            got.push(frame);
        }
    }
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while let Ok(Some(frame)) = tokio::time::timeout_at(deadline, frames.frames.recv()).await {
        got.push(frame);
    }
    (got, claim.state())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn video_frames_ride_a_track_on_the_links_peer_connection() {
    let pair = pair(TransportKind::WebRtc, options(true), options(true)).await;
    assert_eq!(out(&pair.mac).kind().name(), "webrtc-track");
    let (got, state) = stream(&pair, 120).await;
    assert!(got.len() >= 110, "{} frames", got.len());
    assert!(got[0].keyframe, "decoding starts at a keyframe");
    // In order, by capture time.
    for w in got.windows(2) {
        assert!(w[1].rtp_timestamp.wrapping_sub(w[0].rtp_timestamp) < 1 << 31);
    }
    let p = got.iter().find(|f| !f.keyframe).unwrap();
    assert_eq!(&p.access_unit[..5], &[0, 0, 0, 1, 0x41]);
    assert!(state.packets_sent > 200);
    // TWCC feedback flows back.
    assert!(state.feedback_delay_us > 0, "{state:?}");
    // Channels still work beside the track.
    assert!(pair.phone.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn lost_packets_come_back_by_nack_and_frames_stay_decodable() {
    let mac = DialOptions { video_drop_permille: 30, ..options(true) };
    let pair = pair(TransportKind::WebRtc, options(true), mac).await;
    let (got, state) = stream(&pair, 240).await;
    let stats = input(&pair.phone).stats();
    assert!(state.nacks_received > 0, "{state:?}");
    assert!(stats.packets_recovered > 0, "{stats:?}");
    assert!(got.iter().any(|f| f.recovered));
    // Most frames survive 3% loss; any given up restart at a keyframe.
    assert!(got.len() >= 180, "{} frames of 240, {stats:?}", got.len());
    assert!(got[0].keyframe);
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_mac_leaves_the_lane_out_and_the_link_works() {
    let pair = pair(TransportKind::WebRtc, options(true), options(false)).await;
    assert!(pair.phone.media().is_none());
    assert!(pair.mac.media().is_none());
    assert!(pair.phone.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_older_phone_gets_no_track() {
    let pair = pair(TransportKind::WebRtc, options(false), options(true)).await;
    assert!(pair.phone.media().is_none());
    assert!(pair.mac.media().is_none());
    assert!(pair.mac.ping().await.is_ok());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_links_keep_the_reliable_path_for_now() {
    let pair = pair(TransportKind::WireGuard, options(true), options(true)).await;
    assert!(pair.phone.media().is_none());
    assert!(pair.mac.media().is_none());
    pair.phone.close("done");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_newer_claim_preempts_the_older_source() {
    let pair = pair(TransportKind::WebRtc, options(true), options(true)).await;
    let out = out(&pair.mac);
    let mut first = out.claim();
    assert!(first.owns());
    let second = out.claim();
    tokio::time::timeout(Duration::from_secs(1), first.preempted()).await.expect("preempted");
    assert!(!first.owns() && second.owns());
    assert!(
        first.send(OutgoingFrame { access_unit: access_unit(true, 10, 3), capture_us: 0 }).await.is_err()
    );
    pair.phone.close("done");
}
