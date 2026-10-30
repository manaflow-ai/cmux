//! The Chief owner's stop rule on the real binary with a fake owner app
//! (cmux-owner-liveness; principled audit lagQuitHelpers): a `cmux-chief-*`
//! headless owner started with `CMUX_TUI_OWNER_APP_PID` follows that process
//! through its kernel handle. It stays while the app runs, stays while a
//! client is connected after the app died, and stops once the last client
//! leaves (no client, no live owner, no live terminal or brain).
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;

#[path = "support/private_state.rs"]
mod private_state;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

fn stop(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// One request on a connection the caller keeps open (a client).
fn request(stream: &mut BufReader<Box<dyn transport::Stream>>, value: &serde_json::Value) {
    let mut writer = stream.get_ref().try_clone_box().expect("clone the client");
    writeln!(writer, "{value}").expect("send");
    let mut line = String::new();
    stream.read_line(&mut line).expect("an answer");
}

fn exits_within(child: &mut Child, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if child.try_wait().unwrap().is_some() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

fn scratch() -> PathBuf {
    // Below /tmp (private_state.rs) and short: the socket path must stay
    // under the macOS limit.
    let dir = PathBuf::from("/tmp").join(format!("cmux-olc-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(dir.join("home/tui")).unwrap();
    dir
}

fn start_owner(dir: &Path, app: &Child) -> Child {
    let socket = dir.join("mux.sock");
    let stderr = fs::File::create(dir.join("stderr.log")).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    private_state::use_private_state(&mut command, dir);
    // A session of this test's own (two checkouts on one host never share it).
    let session = format!("cmux-chief-olc{}", std::process::id());
    let child = command
        .args(["--headless", "--session", &session])
        .arg("--socket")
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("home/tui"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_OWNER_APP_PID", app.id().to_string())
        .env("HOME", dir.join("home"))
        .env_remove("CMUX_BUNDLE_ID")
        .env_remove("CMUX_TAG")
        .env_remove("CMUX_TUI_CHIEF_BRAINS")
        .stdout(Stdio::null())
        .stderr(stderr)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    while transport::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "the owner did not create {}", socket.display());
        std::thread::sleep(Duration::from_millis(25));
    }
    child
}

#[test]
fn owner_liveness_a_chief_owner_follows_its_fake_app_and_stops_after_it_is_gone() {
    let dir = scratch();
    let mut app = Command::new("sleep").arg("600").spawn().expect("a fake app");
    let mut owner = start_owner(&dir, &app);
    let log = || fs::read_to_string(dir.join("stderr.log")).unwrap_or_default();
    // The app runs, no client: the owner stays past the owner-exit grace.
    if exits_within(&mut owner, Duration::from_secs(4)) {
        stop(&mut app);
        panic!("the Chief owner exited while its app runs:\n{}", log());
    }
    // A client connects; then the app quits. The client keeps the owner.
    let stream = transport::connect(&dir.join("mux.sock")).expect("a client");
    let mut client = BufReader::new(stream);
    request(&mut client, &serde_json::json!({"cmd": "list-workspaces"}));
    stop(&mut app);
    if exits_within(&mut owner, Duration::from_secs(4)) {
        panic!("the Chief owner exited while a client was connected:\n{}", log());
    }
    // The last client leaves: nothing keeps the owner.
    drop(client);
    let exited = exits_within(&mut owner, test_timeout(Duration::from_secs(15)));
    let stderr = log();
    if !exited {
        stop(&mut owner);
    }
    let _ = fs::remove_dir_all(&dir);
    assert!(
        exited,
        "the Chief owner ran 15 s after its app was gone and its last client left:\n{stderr}"
    );
}
