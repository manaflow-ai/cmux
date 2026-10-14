//! A streamed browser tab end to end: the exported viewer, a real link over
//! both transports, cnx-hostd's `browser` service, and a stand-in host.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use cnx_ffi::{BrowserFrame, BrowserObserver, ConnectRequest, Transport, connect_inner};
use cnx_hostd::config::{AcpmuxTarget, ServiceConfig};
use cnx_hostd::host::{AnswerContext, IceSource, serve_signaling};
use cnx_link::SignalingClient;
use cnx_link::testing::{FakeOptions, FakeSignaling};

#[path = "../../cnx-hostd/tests/support/fake_rb_host.rs"]
mod fake_rb_host;

#[derive(Default)]
struct Recorder {
    frames: Mutex<Vec<BrowserFrame>>,
    messages: Mutex<Vec<serde_json::Value>>,
    closed: Mutex<Option<String>>,
}

impl BrowserObserver for Recorder {
    fn on_frame(&self, frame: BrowserFrame) {
        self.frames.lock().unwrap().push(frame);
    }
    fn on_message(&self, json: String) {
        self.messages.lock().unwrap().push(serde_json::from_str(&json).unwrap());
    }
    fn on_closed(&self, code: String, _reason: String) {
        *self.closed.lock().unwrap() = Some(code);
    }
}

impl Recorder {
    async fn until(&self, what: &str, check: impl Fn(&Recorder) -> bool) {
        for _ in 0..400 {
            if check(self) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("timed out waiting for {what}; messages {:?}", self.messages.lock().unwrap());
    }

    fn has(&self, t: &str, key: &str, value: &str) -> bool {
        self.messages
            .lock()
            .unwrap()
            .iter()
            .any(|m| m["t"] == t && m[key].as_str().is_some_and(|v| v.contains(value)))
    }
}

async fn stream_over(transport: Transport) {
    let server = FakeSignaling::start(FakeOptions::default()).await;
    let sockets = tempfile::tempdir().unwrap();
    let launches = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let services = ServiceConfig {
        tui_socket_dir: sockets.path().to_path_buf(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: Vec::new(),
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        browser: cnx_hostd::browser::BrowserConfig::new(Some(fake_rb_host::launcher(launches)), 2),
        chief_socket: None,
        agent_tab_host: None,
        uploads_dir: sockets.path().join("uploads"),
        upload_max_bytes: 1024 * 1024,
        pairing: None,
    };
    let mac_id = uuid::Uuid::new_v4().to_string();
    let mac = SignalingClient::connect(&server.base_url, "user:alice", "team", &mac_id).await.unwrap();
    tokio::spawn(serve_signaling(
        mac,
        AnswerContext {
            owner_user_id: "alice".into(),
            services: Arc::new(services),
            ice: IceSource::Fixed(Vec::new()),
            include_loopback: true,
            exclude_cgnat: false,
        },
    ));
    let handle = connect_inner(
        ConnectRequest {
            base_url: server.base_url.clone(),
            token: "user:alice".into(),
            team_id: "team".into(),
            device_id: uuid::Uuid::new_v4().to_string(),
            mac_device_id: mac_id,
            transport,
            include_loopback: true,
            relay_only: false,
        },
        None,
    )
    .await
    .expect("connect");
    let recorder = Arc::new(Recorder::default());
    let stream = handle
        .open_browser(r#"{"tab":"s3","url":"https://example.com/"}"#.into(), recorder.clone())
        .await
        .unwrap();
    recorder.until("welcome", |r| r.has("welcome", "encoder", "fake")).await;
    recorder.until("rb.page", |r| r.has("rb.page", "url", "example.com")).await;
    stream
        .send_message(
            serde_json::json!({"t": "rb.open", "tab": "s3", "profile": "default", "viewer": "phone",
                "screen": {"css_width": 402, "css_height": 760, "scale": 2.0, "refresh_hz": 60, "color_space": "srgb"},
                "caps": {"codecs": ["h264"], "tile_codecs": [], "max_fps": 60}})
            .to_string(),
        )
        .unwrap();
    recorder
        .until("rb.screen_applied", |r| {
            r.messages
                .lock()
                .unwrap()
                .iter()
                .any(|m| m["t"] == "rb.screen_applied" && m["pixel_width"] == 804.0)
        })
        .await;
    // Frames arrive whole, the first a keyframe, and get an age once the clock is estimated.
    recorder
        .until("frames with an age", |r| r.frames.lock().unwrap().iter().any(|f| f.age_us.is_some()))
        .await;
    {
        let frames = recorder.frames.lock().unwrap();
        assert!(frames[0].keyframe);
        assert_eq!(frames[0].access_unit.len(), 2500);
        let aged = frames.iter().find_map(|f| f.age_us).unwrap();
        assert!((0..2_000_000).contains(&aged), "age {aged}");
    }
    stream.send_message(r#"{"t":"rb.navigate","url":"https://example.org/x"}"#.into()).unwrap();
    recorder.until("navigated", |r| r.has("rb.page", "url", "example.org/x")).await;
    stream
        .send_input(
            r#"{"e":"pointer","surface":0,"kind":"down","x":10.0,"y":20.0,"button":0,"buttons":1,"click_count":1,"modifiers":0,"pointer_type":"touch"}"#
                .into(),
            true,
        )
        .unwrap();
    stream
        .send_input(r#"{"e":"ime_commit","surface":0,"text":"héllo","replacement":null}"#.into(), true)
        .unwrap();
    recorder.until("input reached the page", |r| r.has("rb.tooltip", "text", "pointer")).await;
    recorder.until("text reached the page", |r| r.has("rb.tooltip", "text", "héllo")).await;
    assert!(stream.send_message(r#"{"t":"welcome"}"#.into()).is_err());
    let stats = stream.stats();
    assert!(stats.frames >= 1 && stats.bytes >= 2500 && stats.clock_offset_us.is_some());
    stream.close();
    recorder.until("closed", |r| r.closed.lock().unwrap().is_some()).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_stream_over_webrtc() {
    stream_over(Transport::WebRtc).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn browser_stream_over_wireguard() {
    stream_over(Transport::WireGuard).await;
}
