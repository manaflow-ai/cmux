//! The Linux host end to end (docs/remote-browser-on-vm.md, slice 1): a real
//! headless Chromium over the DevTools pipe, screencast frames encoded with
//! OpenH264 (built from source here), served over rd/1 to the probe viewer,
//! which sends keys and times each to its frame.
//!
//! Needs a Chromium: `CMUX_RB_CHROMIUM`, `CMUX_CHROME_HEADLESS_SHELL` (what
//! `scripts/ci/ensure-system-chrome.sh` prints) or one on `PATH`. Without one
//! the test says so and passes, unless `CMUX_RB_REQUIRE_CHROMIUM` is set.
//! As root (CI containers) set `CMUX_RB_NO_SANDBOX=1`.
//! When `FAST_CHECKS_OUT` is set the probe's numbers are written there.

#![cfg(all(unix, not(target_os = "macos")))]

use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_encode::openh264::OpenH264Api;
use cmux_remote_browser_host::cdp_serve::{self, FrameStages, Options};
use cmux_remote_browser_host::probe::{self, Plan};

/// Each keydown toggles a 16x16 box, so each key makes one new frame.
const PAGE: &str = "data:text/html,<html><body style='margin:0;background:%231f7a3a'>\
<div id=b style='position:absolute;left:100px;top:100px;width:16px;height:16px;\
background:red'></div><script>let n=0;addEventListener('keydown',()=>{n++;\
document.getElementById('b').style.background=n%252?'blue':'red';});\
document.title='ready';</script></body></html>";

const KEYS: usize = 10;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("cmux-rb-cdp-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Median milliseconds of each host stage over the frames a key caused:
/// input dispatch to Chromium's capture, capture to the pipe message, the
/// loop's queue, base64, JPEG decode, I420, encode, send.
fn stage_summary(stages: &[FrameStages]) -> String {
    let keyed: Vec<&FrameStages> = stages.iter().filter(|s| s.input_sent_us.is_some()).collect();
    let median = |f: &dyn Fn(&FrameStages) -> Option<u64>| {
        let mut v: Vec<f64> =
            keyed.iter().filter_map(|s| f(s)).map(|us| us as f64 / 1000.0).collect();
        v.sort_by(f64::total_cmp);
        v.get(v.len() / 2).map(|m| format!("{m:.1}")).unwrap_or_else(|| "none".into())
    };
    let d = |a: u64, b: u64| Some(b.saturating_sub(a));
    let mut out = format!("stage_frames={} keyed={}\n", stages.len(), keyed.len());
    let rows: [(&str, &dyn Fn(&FrameStages) -> Option<u64>); 10] = [
        ("input_rx_to_sent", &|s| d(s.input_rx_us?, s.input_sent_us?)),
        ("input_to_capture", &|s| d(s.input_sent_us?, s.captured_us?)),
        ("capture_to_arrive", &|s| d(s.captured_us?, s.arrived_us)),
        ("input_to_arrive", &|s| d(s.input_sent_us?, s.arrived_us)),
        ("queue", &|s| d(s.arrived_us, s.picked_us)),
        ("base64", &|s| d(s.picked_us, s.unpacked_us)),
        ("jpeg_decode", &|s| d(s.unpacked_us, s.decoded_us)),
        ("i420", &|s| d(s.decoded_us, s.converted_us)),
        ("encode", &|s| d(s.converted_us, s.encoded_us)),
        ("input_to_sent", &|s| d(s.input_sent_us?, s.sent_us)),
    ];
    for (name, f) in rows {
        out += &format!("stage_{name}_p50_ms={}\n", median(f));
    }
    let bytes: Vec<usize> = keyed.iter().map(|s| s.jpeg_bytes).collect();
    out += &format!("jpeg_bytes={bytes:?}\n");
    out
}

#[test]
fn headless_chromium_tab_streams_and_answers_keys() {
    let Some(chromium) = cmux_remote_browser_host::chromium::find() else {
        assert!(
            std::env::var_os("CMUX_RB_REQUIRE_CHROMIUM").is_none(),
            "CMUX_RB_REQUIRE_CHROMIUM is set and no Chromium was found \
             (set CMUX_CHROME_HEADLESS_SHELL from scripts/ci/ensure-system-chrome.sh)"
        );
        eprintln!("SKIP: no Chromium (set CMUX_RB_CHROMIUM or CMUX_CHROME_HEADLESS_SHELL)");
        return;
    };
    let root = scratch("e2e");
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let secret = "test-secret".to_string();
    let stages = Arc::new(Mutex::new(Vec::<FrameStages>::new()));
    let opts = Options {
        url: PAGE.into(),
        secret: Some(secret.clone()),
        once: true,
        lifeline: false,
        chromium: chromium.clone(),
        profile: root.join("profile"),
        encoder: Arc::new(|| Ok(OpenH264Api::from_source())),
        stages: Some(stages.clone()),
    };
    let (done, exited) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = done.send(cdp_serve::run(listener, opts));
    });

    let out = root.join("probe");
    std::fs::create_dir_all(&out).expect("probe dir");
    let plan = Plan { keys: KEYS, idle_ms: 2000, settle_ms: 1500, ..Plan::default() };
    let report = probe::run(addr, &out, plan, Some(&secret));
    let code = exited.recv_timeout(Duration::from_secs(20));

    let mut sorted = report.latencies_ms.clone();
    sorted.sort_by(f64::total_cmp);
    let pct = |p: f64| sorted.get(((sorted.len() as f64 - 1.0) * p).round() as usize).copied();
    let summary = format!(
        "chromium={}\nerror={:?}\nframes={}\nkeyframes={}\nbytes={}\nfirst_frame_ms={:?}\n\
         idle_frames={:?}\nkeys_sent={}\nlatencies={}\nkey_to_frame_p50_ms={:?}\n\
         key_to_frame_max_ms={:?}\nhost_exit={code:?}\n",
        chromium.display(),
        report.error,
        report.frames,
        report.keyframes,
        report.bytes,
        report.first_frame_ms,
        report.idle_frames,
        report.keys_sent,
        report.latencies_ms.len(),
        pct(0.5),
        sorted.last(),
    );
    let summary = format!(
        "{summary}build={}\n{}",
        if cfg!(debug_assertions) { "debug" } else { "release" },
        stage_summary(&stages.lock().expect("stages"))
    );
    eprintln!("{summary}");
    if let Some(dir) = std::env::var_os("FAST_CHECKS_OUT") {
        let dir = PathBuf::from(dir);
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::fs::write(dir.join("cdp_host.txt"), &summary);
        let _ = std::fs::copy(out.join("result.json"), dir.join("cdp_host_result.json"));
    }

    assert_eq!(report.error, None, "probe failed");
    assert!(report.keyframes >= 1, "no keyframe");
    assert!(report.first_frame_ms.is_some(), "no first frame");
    assert_eq!(report.keys_sent, KEYS);
    assert_eq!(report.latencies_ms.len(), KEYS, "every key makes a frame");
    assert_eq!(code, Ok(0), "the host exits once its only viewer left");
    let _ = std::fs::remove_dir_all(&root);
}
