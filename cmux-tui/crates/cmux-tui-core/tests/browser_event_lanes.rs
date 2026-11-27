//! Browser surfaces share the CDP event-lane pool: N live browser surfaces add
//! no event thread each (perf-lead F6, chrome-parity p01-process task 206).
//! Its own test binary, so the process thread count is this test's alone.
#![cfg(any(target_os = "linux", target_os = "macos"))]

use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::os::unix::net::UnixStream;
use std::thread;
use std::time::{Duration, Instant};

mod support;
use base64::Engine as _;
use cmux_tui_core::{BrowserStatus, Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use support::DaemonMuxOps;
use tungstenite::{Message, accept};

const SURFACES: usize = 20;
/// Threads the shared browser runtime may add besides one command worker per
/// surface: the CDP client's socket threads, the runtime's router and the
/// event-lane pool (7 measured on Linux). With an event thread per surface
/// the same 20 surfaces add about 20 more.
const SHARED_THREAD_ALLOWANCE: usize = 12;

fn process_threads() -> usize {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_dir("/proc/self/task").unwrap().count()
    }
    #[cfg(target_os = "macos")]
    {
        let mut info: libc::proc_taskinfo = unsafe { std::mem::zeroed() };
        let size = size_of::<libc::proc_taskinfo>() as libc::c_int;
        // SAFETY: `info` is a writable proc_taskinfo of exactly `size` bytes.
        let written = unsafe {
            libc::proc_pidinfo(
                std::process::id() as libc::c_int,
                libc::PROC_PIDTASKINFO,
                0,
                (&mut info as *mut libc::proc_taskinfo).cast(),
                size,
            )
        };
        assert_eq!(written, size, "proc_pidinfo(PROC_PIDTASKINFO)");
        info.pti_threadnum as usize
    }
}

fn read_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>) -> Option<Value> {
    loop {
        match ws.read().ok()? {
            Message::Text(text) => return Some(serde_json::from_str(&text).unwrap()),
            Message::Binary(bytes) => return Some(serde_json::from_slice(&bytes).unwrap()),
            Message::Close(_) => return None,
            _ => {}
        }
    }
}

fn write_json(ws: &mut tungstenite::WebSocket<std::net::TcpStream>, value: Value) {
    ws.send(Message::Text(value.to_string().into())).unwrap();
}

fn wait_for<T>(mut f: impl FnMut() -> Option<T>, timeout: Duration) -> Option<T> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(value) = f() {
            return Some(value);
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

/// A provider CDP endpoint with targets `target-<i>`: each attach answers
/// `session-<i>` and each screencast start sends one frame whose data names
/// its session, so a frame on a surface proves its event lane ran.
fn spawn_cdp_server(listener: TcpListener) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        while let Some(request) = read_json(&mut ws) {
            let id = request["id"].clone();
            match request["method"].as_str().unwrap_or_default() {
                "Target.attachToTarget" => {
                    let target = request["params"]["targetId"].as_str().unwrap();
                    let session = target.replace("target-", "session-");
                    write_json(&mut ws, json!({"id": id, "result": {"sessionId": session}}));
                }
                "Page.getFrameTree" => write_json(
                    &mut ws,
                    json!({"id": id, "result": {"frameTree": {"frame": {
                        "id": "main-frame", "loaderId": "loader-1", "url": "https://example.test"
                    }}}}),
                ),
                "Page.startScreencast" => {
                    let session = request["sessionId"].as_str().unwrap().to_string();
                    write_json(&mut ws, json!({"id": id, "result": {}}));
                    let data = base64_of(&session);
                    write_json(
                        &mut ws,
                        json!({
                            "method": "Page.screencastFrame",
                            "sessionId": session,
                            "params": {
                                "data": data,
                                "metadata": {"deviceWidth": 80, "deviceHeight": 40},
                                "sessionId": 1
                            }
                        }),
                    );
                }
                _ if !id.is_null() => write_json(&mut ws, json!({"id": id, "result": {}})),
                _ => {}
            }
        }
    })
}

fn base64_of(text: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(text)
}

fn register_provider(path: &std::path::Path, endpoint: String, targets: Vec<Value>) -> UnixStream {
    let mut stream = UnixStream::connect(path).unwrap();
    let mut line = json!({
        "id": 1,
        "cmd": "register-browser-provider",
        "provider_id": "browser-event-lanes",
        "endpoint": endpoint,
        "authentication": "none",
        "targets": targets,
    })
    .to_string()
    .into_bytes();
    line.push(b'\n');
    stream.write_all(&line).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut response = String::new();
    reader.read_line(&mut response).unwrap();
    let response: Value = serde_json::from_str(&response).unwrap();
    assert_eq!(response["ok"], true, "browser provider registration failed: {response}");
    stream
}

#[test]
fn live_browser_surfaces_add_no_event_thread_each() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let cdp_server = spawn_cdp_server(listener);

    let mux = Mux::new("browser-event-lanes-test", SurfaceOptions::default());
    let socket_path = std::env::temp_dir()
        .join(format!("cmux-browser-event-lanes-{}", std::process::id()))
        .join("session.sock");
    server::serve(mux.clone(), Some(socket_path.clone())).unwrap();
    let before = process_threads();

    let surfaces = (0..SURFACES)
        .map(|_| {
            mux.new_browser_tab("https://example.test".to_string(), None, Some((10, 5)))
                .expect("browser tab")
        })
        .collect::<Vec<_>>();
    let targets = surfaces
        .iter()
        .enumerate()
        .map(|(index, surface)| {
            let tab_id = mux
                .surface(surface.id)
                .and_then(|surface| {
                    surface.resource_identity().map(|identity| identity.tab_id.to_string())
                })
                .expect("browser surface has a tab identity");
            json!({"tab_id": tab_id, "target_id": format!("target-{index}")})
        })
        .collect::<Vec<_>>();
    let provider =
        register_provider(&socket_path, format!("ws://{addr}/devtools/browser/lanes"), targets);

    for (index, surface) in surfaces.iter().enumerate() {
        let session = format!("session-{index}");
        let data = base64_of(&session);
        wait_for(
            || {
                let frame = surface.browser_frame()?;
                (matches!(surface.browser_status(), Some(BrowserStatus::Live))
                    && frame.session_id == session
                    && frame.data_b64 == data)
                    .then_some(())
            },
            Duration::from_secs(20),
        )
        .unwrap_or_else(|| panic!("surface {index} never showed its own frame"));
    }

    // Bootstrap threads end once their attach is published; what stays is
    // what each live surface costs.
    let bound = before + SURFACES + SHARED_THREAD_ALLOWANCE;
    let settled = wait_for(
        || {
            let threads = process_threads();
            (threads <= bound).then_some(threads)
        },
        Duration::from_secs(10),
    );
    let after = process_threads();
    println!(
        "browser-event-lanes: {SURFACES} live browser surfaces added {} threads ({before} -> {after})",
        after.saturating_sub(before)
    );
    assert!(
        settled.is_some(),
        "{SURFACES} live browser surfaces added {} threads (allowed {}: one command worker each \
         plus {SHARED_THREAD_ALLOWANCE} shared); a surface must not own an event thread",
        after.saturating_sub(before),
        SURFACES + SHARED_THREAD_ALLOWANCE
    );

    drop(provider);
    mux.shutdown();
    server::cleanup(&socket_path);
    drop(cdp_server);
}
