//! The first frame (RFD 0003, publish step 7): its size fit, its request, the real agent socket
//! against a mock agent, and the headless capture against a stand-in browser.
#![cfg(unix)]

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use cmux_apps::frame::{FRAME_BUDGET, FRAME_LIMIT, Rgba, fit, is_png};
use cmux_apps::io::Capture as _;
use cmux_apps::platform::{PlatformApi as _, PlatformClient, frame_body};
use cmux_apps::system::{AgentSocket, HeadlessCapture, capture_args, find_browser};
use serde_json::{Value, json};

/// A scratch directory of this test's own, removed when it drops.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir =
            std::env::temp_dir().join(format!("cmux-apps-frame-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Scratch(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Pixels a PNG can't squeeze: a cheap xorshift noise, opaque.
fn noise(width: u32, height: u32) -> Rgba {
    let mut state: u32 = 0x9e37_79b9;
    let mut pixels = Vec::with_capacity(width as usize * height as usize * 4);
    for _ in 0..width * height {
        for _ in 0..3 {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            pixels.push(state as u8);
        }
        pixels.push(255);
    }
    Rgba { width, height, pixels }
}

fn dimensions(png: &[u8]) -> (u32, u32) {
    let reader = png::Decoder::new(std::io::Cursor::new(png)).read_info().unwrap();
    (reader.info().width, reader.info().height)
}

#[test]
fn a_frame_that_fits_is_sent_as_it_is() {
    let png = Rgba { width: 4, height: 2, pixels: vec![200; 32] }.encode().unwrap();
    assert_eq!(fit(&png, FRAME_BUDGET).unwrap(), png);
}

#[test]
fn a_frame_over_the_budget_is_halved_until_it_fits() {
    let png = noise(1280, 800).encode().unwrap();
    assert!(png.len() > FRAME_BUDGET, "the fixture must start over budget: {}", png.len());
    let fitted = fit(&png, FRAME_BUDGET).unwrap();
    assert!(is_png(&fitted));
    assert!(fitted.len() <= FRAME_BUDGET, "{} bytes", fitted.len());
    let (w, h) = dimensions(&fitted);
    // Each step halves both sides, so the aspect stays 16:10.
    assert!((160..1280).contains(&w), "{w}x{h}");
    assert_eq!(w * 10, h * 16, "{w}x{h}");
}

#[test]
fn a_plain_page_fits_at_full_size_by_re_encoding() {
    // A plain page (every row the same gradient) as a fast, unfiltered encoder wrote it: over
    // budget, but its pixels compress, so it keeps every pixel.
    let row: Vec<u8> =
        (0..1280u32).flat_map(|x| [(x % 251) as u8, (x % 241) as u8, 90, 255]).collect();
    let page = Rgba { width: 1280, height: 800, pixels: row.repeat(800) };
    let mut loose = Vec::new();
    let mut encoder = png::Encoder::new(&mut loose, 1280, 800);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    encoder.set_filter(png::FilterType::NoFilter);
    encoder.set_adaptive_filter(png::AdaptiveFilterType::NonAdaptive);
    let mut writer = encoder.write_header().unwrap();
    writer.write_image_data(&page.pixels).unwrap();
    writer.finish().unwrap();
    assert!(loose.len() > FRAME_BUDGET, "the fixture must start over budget: {}", loose.len());
    let fitted = fit(&loose, FRAME_BUDGET).unwrap();
    assert_eq!(dimensions(&fitted), (1280, 800));
}

#[test]
fn a_frame_that_cannot_fit_is_refused_not_faked() {
    let png = noise(400, 400).encode().unwrap();
    let refused = fit(&png, 64).unwrap_err();
    assert!(refused.contains("no frame fits"), "{refused}");
}

#[test]
fn a_capture_that_is_not_a_png_is_refused() {
    assert!(fit(b"<!doctype html><p>Sign in</p>", FRAME_BUDGET).unwrap_err().contains("not a PNG"));
    let mut broken = noise(8, 8).encode().unwrap();
    broken.truncate(20);
    broken.resize(FRAME_BUDGET + 1, 0);
    assert!(fit(&broken, FRAME_BUDGET).is_err());
}

#[test]
fn halving_averages_each_two_by_two_block() {
    let image = Rgba {
        width: 2,
        height: 2,
        pixels: vec![0, 0, 0, 255, 100, 100, 100, 255, 200, 200, 200, 255, 100, 100, 100, 255],
    };
    assert_eq!(image.halved(), Rgba { width: 1, height: 1, pixels: vec![100, 100, 100, 255] });
}

#[test]
fn the_budget_fits_the_platform_and_the_agents_line() {
    // The platform keeps up to 256 KiB decoded.
    const { assert!(FRAME_BUDGET <= FRAME_LIMIT) };
    // The agent refuses an apps.call body over 64 KiB and a socket line over 64 KiB
    // (cmux-host cloud::apps_call MAX_BODY, cloud::role MAX_LINE): a full-budget frame, with
    // the longest apps path (256 bytes), stays under both.
    let body = frame_body(&vec![0xab; FRAME_BUDGET]);
    assert!(body.to_string().len() <= 64 * 1024, "{}", body.to_string().len());
    let line = json!({"apps.call": {
        "method": "PUT",
        "path": "x".repeat(256),
        "body": body,
        "idempotencyKey": null,
    }});
    assert!(line.to_string().len() < 64 * 1024, "{}", line.to_string().len());
}

#[test]
fn the_frame_body_is_only_the_png_in_standard_base64() {
    let png = Rgba { width: 1, height: 1, pixels: vec![1, 2, 3, 255] }.encode().unwrap();
    let body = frame_body(&png);
    assert_eq!(body.as_object().unwrap().keys().collect::<Vec<_>>(), ["png"]);
    let text = body["png"].as_str().unwrap();
    assert_eq!(base64::engine::general_purpose::STANDARD.decode(text).unwrap(), png);
}

/// A stand-in for this machine's agent: answers one `apps.call` line with `answer` and hands
/// back the line it got.
fn mock_agent(socket: &Path, answer: Value) -> std::thread::JoinHandle<Value> {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let mut stream = stream;
        stream.write_all(format!("{answer}\n").as_bytes()).unwrap();
        serde_json::from_str(line.trim()).unwrap()
    })
}

#[test]
fn put_frame_sends_one_apps_call_line_through_the_agent_socket() {
    let scratch = Scratch::new("socket");
    let socket = scratch.0.join("agent.sock");
    let agent =
        mock_agent(&socket, json!({"ok": true, "status": 200, "body": {}, "machine": "m_1"}));
    let transport = AgentSocket { path: socket };
    let png = noise(64, 40).encode().unwrap();
    PlatformClient::new(&transport).put_frame("web", 3, &png).unwrap();

    let line = agent.join().unwrap();
    let call = &line["apps.call"];
    assert_eq!(call["method"], "PUT");
    assert_eq!(call["path"], "/v1/cloud/apps/web/versions/3/frame");
    assert_eq!(call["idempotencyKey"], Value::Null);
    let sent = base64::engine::general_purpose::STANDARD
        .decode(call["body"]["png"].as_str().unwrap())
        .unwrap();
    assert_eq!(sent, png);
}

#[test]
fn put_frame_surfaces_the_platforms_refusal() {
    let scratch = Scratch::new("refusal");
    let socket = scratch.0.join("agent.sock");
    let agent = mock_agent(
        &socket,
        json!({"ok": true, "status": 413, "machine": "m_1", "body": {"error": {
            "code": "cloud.app.frame_too_large", "message": "over 256 KiB"}}}),
    );
    let transport = AgentSocket { path: socket };
    let png = noise(4, 4).encode().unwrap();
    let refused = PlatformClient::new(&transport).put_frame("web", 1, &png).unwrap_err();
    agent.join().unwrap();
    assert_eq!((refused.status, refused.code.as_str()), (413, "cloud.app.frame_too_large"));
}

/// Held by every test that writes a stand-in browser or starts one: a script written while
/// another thread forks stays open for writing in that child, and running it is ETXTBSY.
static BROWSERS: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn browsers() -> std::sync::MutexGuard<'static, ()> {
    BROWSERS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// A stand-in browser: a shell script that writes `png` to its `--screenshot=` path and
/// records its arguments beside it.
fn fake_browser(dir: &Path, png: &[u8], exit: i32) -> PathBuf {
    let fixture = dir.join("fixture.png");
    std::fs::write(&fixture, png).unwrap();
    let args = dir.join("args");
    let script = dir.join("chrome");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\nfor a in \"$@\"; do echo \"$a\" >> '{args}'; case \"$a\" in --screenshot=*) cp '{fixture}' \"${{a#--screenshot=}}\";; --user-data-dir=*) [ -e \"${{a#--user-data-dir=}}\" ] && echo REUSED >> '{args}';; esac; done\nexit {exit}\n",
            args = args.display(),
            fixture = fixture.display(),
        ),
    )
    .unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

#[test]
fn the_capture_renders_loopback_in_a_fresh_profile_and_cleans_it_up() {
    let _browsers = browsers();
    let scratch = Scratch::new("browser");
    let png = noise(32, 20).encode().unwrap();
    let capture = HeadlessCapture { browser: Some(fake_browser(&scratch.0, &png, 0)) };
    assert_eq!(capture.png(41000).unwrap(), png);

    let args = std::fs::read_to_string(scratch.0.join("args")).unwrap();
    let args: Vec<&str> = args.lines().collect();
    assert_eq!(args.last(), Some(&"http://127.0.0.1:41000/"));
    assert!(args.contains(&"--headless=new"), "{args:?}");
    assert!(!args.contains(&"REUSED"), "the profile existed before the render: {args:?}");
    let profile = args.iter().find_map(|a| a.strip_prefix("--user-data-dir=")).unwrap();
    assert!(
        !Path::new(profile).parent().unwrap().exists(),
        "the capture's directory outlived it: {profile}"
    );
}

#[test]
fn a_browser_that_fails_gives_no_frame() {
    let _browsers = browsers();
    let scratch = Scratch::new("fails");
    let capture = HeadlessCapture { browser: Some(fake_browser(&scratch.0, b"", 3)) };
    let failed = capture.png(41000).unwrap_err();
    assert!(failed.contains("exited"), "{failed}");
}

#[test]
fn the_capture_args_use_no_sandbox_only_as_root() {
    let p = Path::new("/tmp/p");
    let o = Path::new("/tmp/o.png");
    assert!(!capture_args(1, p, o, false).iter().any(|a| a == "--no-sandbox"));
    assert!(capture_args(1, p, o, true).iter().any(|a| a == "--no-sandbox"));
    assert!(capture_args(1, p, o, false).contains(&"--window-size=1280,800".to_owned()));
}

#[test]
fn the_browser_is_the_images_named_one_else_the_first_on_path() {
    let scratch = Scratch::new("find");
    let bin = scratch.0.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let chromium = bin.join("chromium");
    std::fs::write(&chromium, "").unwrap();
    let path_var = bin.display().to_string();
    assert_eq!(find_browser(None, Some(&path_var)), Some(chromium.clone()));
    let named = scratch.0.join("chrome-named");
    std::fs::write(&named, "").unwrap();
    assert_eq!(find_browser(Some(named.to_str().unwrap()), Some(&path_var)), Some(named));
    assert_eq!(find_browser(Some("/no/such/chrome"), Some(&path_var)), Some(chromium));
    assert_eq!(find_browser(None, None), None);
}

/// With a real browser on this machine (the Cloud image has Chrome), a real page on loopback
/// renders to a PNG that fits. Without one there is nothing to render, and the test says so.
#[test]
fn a_real_browser_renders_a_loopback_page_that_fits() {
    let _browsers = browsers();
    let Some(browser) = find_browser(
        std::env::var("AGENT_BROWSER_EXECUTABLE_PATH").ok().as_deref(),
        std::env::var("PATH").ok().as_deref(),
    ) else {
        eprintln!("notice: no headless browser here; the real render was not run");
        return;
    };
    let server = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = server.local_addr().unwrap().port();
    // Detached: the render is bounded by the capture, and the server must not hold the test.
    std::thread::spawn(move || {
        // Chrome may open more than one connection (favicon); answer each until it's done.
        server.set_nonblocking(false).unwrap();
        for stream in server.incoming().take(4) {
            let Ok(mut stream) = stream else { break };
            // A speculative connection may never send a request.
            let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(2)));
            let mut request = [0u8; 2048];
            let _ = std::io::Read::read(&mut stream, &mut request);
            let page = "<!doctype html><body style=\"background:#123456;color:#fff;font:40px sans-serif\"><h1>first frame</h1>";
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{page}",
                page.len()
            );
            if request.starts_with(b"GET / ") {
                break;
            }
        }
    });
    let png = HeadlessCapture { browser: Some(browser) }.png(port).unwrap();
    assert!(is_png(&png));
    assert_eq!(dimensions(&png), (1280, 800));
    let fitted = fit(&png, FRAME_BUDGET).unwrap();
    assert!(fitted.len() <= FRAME_BUDGET);
}
