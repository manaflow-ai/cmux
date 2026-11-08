//! Before/after harness: "agent start or resume -> relay registered" on a
//! bound Cloud machine, with the real Cloud role (`CloudRole::start`, its
//! worker, GitHub minter and, where the revision has it, the carrier ticket
//! thread) against a fake platform on loopback. Ignored in normal runs:
//!
//! ```text
//! HARNESS_PROFILE=before|after HARNESS_RUNS=10 \
//!   cargo test -p cmux-host --lib carrier_register_harness -- --ignored --nocapture
//! ```
//!
//! The fake platform answers every request after 150 ms, a status report
//! (`/v1/ops`) after 8 s and a GitHub token mint after 6 s. At each start
//! and each resume, three GitHub token asks arrive on the agent socket with
//! the session host's ticket asks, as a machine's git and `gh` helpers do.
//!
//! The session host's side is a model of cmux-remote's registration loop
//! (`relay.rs`, `relay_liveness.rs`), driven by the real socket asks of
//! `host cloud carrier-ticket` (the carrier socket, else the agent socket,
//! one line, a 30 s read). The relay itself answers at once. The profile
//! gives the session host's numbers of each revision:
//!
//! - `before`: a 10 s ticket command timeout; after a resume, a dead
//!   registration is found by an unanswered ping (1 s check, 3 s pong
//!   timeout: 3 to 4 s), then a 0 to 100 ms relay backoff.
//! - `after`: a 35 s ticket command timeout; after a resume, the first 1 s
//!   check sees the pause and registers with no wait (0 to 1 s).
//!
//! After a failed ticket ask the model waits the credential backoff (full
//! jitter, 1 s doubling to 60 s), as cmux-remote does.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use cmux_server_core::platform::{InstallMode, Platform};
use cmux_server_core::role::{HostEvent, Role, RoleContext, StopContext};
use serde_json::{Value, json};

use super::{CloudRole, TEST_ORIGIN};
use crate::cloud::wire::{Bound, Env};
use crate::config::Paths;

const MACHINE: &str = "vm_harness000000000000a";
const TEAM: &str = "team_t0000000000000000001";
const USER: &str = "user_u0000000000000000001";
const INSTALL: &str = "inst_v0000000000000000004";
const GRANT: &str = "grant_v000000000000000004";
const INSTANCE: &str = "i-harness";
const BASE_LATENCY: Duration = Duration::from_millis(150);
const REPORT_LATENCY: Duration = Duration::from_secs(8);
const MINT_LATENCY: Duration = Duration::from_secs(6);
const MINTS_PER_PHASE: usize = 3;
/// `host cloud carrier-ticket`'s read of the agent's answer.
const CLI_WAIT: Duration = Duration::from_secs(30);

fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn unit() -> f64 {
    let mut bytes = [0_u8; 8];
    if std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)).is_err() {
        return 0.5;
    }
    (u64::from_be_bytes(bytes) >> 11) as f64 / (1_u64 << 53) as f64
}

/// The fake platform: one thread per connection, keep-alive.
fn platform() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            std::thread::spawn(move || serve(stream));
        }
    });
    origin
}

fn serve(stream: TcpStream) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    loop {
        let mut request = String::new();
        if reader.read_line(&mut request).unwrap_or(0) == 0 {
            return;
        }
        let mut length = 0_usize;
        loop {
            let mut header = String::new();
            if reader.read_line(&mut header).unwrap_or(0) == 0 {
                return;
            }
            let header = header.trim_end();
            if header.is_empty() {
                break;
            }
            if let Some((name, value)) = header.split_once(':')
                && name.eq_ignore_ascii_case("content-length")
            {
                length = value.trim().parse().unwrap_or(0);
            }
        }
        let mut body = vec![0_u8; length];
        if reader.read_exact(&mut body).is_err() {
            return;
        }
        let path = request.split_whitespace().nth(1).unwrap_or("/").to_owned();
        let (delay, status, answer) = answer(&path);
        std::thread::sleep(delay);
        let text = answer.to_string();
        let head = format!(
            "HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            text.len()
        );
        if writer
            .write_all(head.as_bytes())
            .and_then(|()| writer.write_all(text.as_bytes()))
            .is_err()
        {
            return;
        }
    }
}

fn answer(path: &str) -> (Duration, u16, Value) {
    let now = wall_ms();
    match path {
        "/v1/auth/challenge" => (
            BASE_LATENCY,
            200,
            json!({ "install": INSTALL, "nonce": format!("n-{now}"), "message_prefix": format!("cmux-auth-v1\nproduction\n{INSTALL}\n") }),
        ),
        "/v1/auth/token" => (
            BASE_LATENCY,
            200,
            json!({ "access_token": format!("bearer-{now}"), "token_type": "Bearer", "expires_at": now + 3_600_000, "install": INSTALL, "user": USER, "grant": GRANT, "team": TEAM }),
        ),
        "/v1/ops" => (REPORT_LATENCY, 200, json!({ "ok": true, "value": {} })),
        p if p == crate::cloud::github::TOKEN_PATH => {
            (MINT_LATENCY, 200, json!({ "ok": false, "error": { "code": "harness" } }))
        }
        p if p.ends_with("/carrier") => (
            BASE_LATENCY,
            200,
            json!({ "ok": true, "value": { "relay": "relay+do://relay.example", "slot": "slot_0123456789abcdefghijkl", "ticket": format!("ticket-{now}"), "expires_at": now / 1000 + 300 } }),
        ),
        _ => (BASE_LATENCY, 200, json!({ "ok": true, "value": {} })),
    }
}

fn write(root: &Path, file: &str, text: &str) {
    let path = Paths::new(root).at(file);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, text).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
}

/// A machine bound before this agent start, with a relay carrier.
fn bound_machine(root: &Path) {
    let bound = Bound {
        machine: MACHINE.to_owned(),
        team: TEAM.to_owned(),
        host: "host_h0000000000000000004".to_owned(),
        epoch: 1,
        install: INSTALL.to_owned(),
        user: USER.to_owned(),
        grant: GRANT.to_owned(),
        env: Env::Prod,
        api_origin: Env::Prod.api_origin().to_owned(),
        keyset: Value::Null,
        bound_at: wall_ms(),
    };
    write(root, crate::cloud::wire::BOUND_FILE, &serde_json::to_string(&bound).unwrap());
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    write(
        root,
        crate::cloud::wire::INSTALL_KEY_FILE,
        &json!({ "instance_id": INSTANCE, "pkcs8": key.pkcs8_base64url() }).to_string(),
    );
    write(root, crate::cloud::wire::DAEMON_INFO_FILE, r#"{"version":"harness","capabilities":[]}"#);
    write(
        root,
        crate::carrier_entry::CARRIER_FILE,
        &json!({ "relay": "relay+do://relay.example", "machine": MACHINE, "slot": "slot_0123456789abcdefghijkl", "team": TEAM, "issuer": "cmux:cloud:production", "keyset": { "version": "v1", "keys": {} } }).to_string(),
    );
}

/// One line to the carrier socket (else the agent socket), one reply read
/// within `wait`, as `host cloud carrier-ticket` asks.
fn ask_line(root: &Path, line: &str, wait: Duration) -> Result<Value, String> {
    let paths = Paths::new(root);
    let mut stream = UnixStream::connect(paths.at("/run/cmux-vm-agent/carrier.sock"))
        .or_else(|_| UnixStream::connect(paths.at(crate::cloud::wire::AGENT_SOCKET)))
        .map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(wait)).map_err(|e| e.to_string())?;
    stream.write_all(format!("{line}\n").as_bytes()).map_err(|e| e.to_string())?;
    let mut reply = String::new();
    BufReader::new(stream).read_line(&mut reply).map_err(|e| e.to_string())?;
    serde_json::from_str(&reply).map_err(|e| e.to_string())
}

/// Three GitHub token asks on the agent socket, each on its own thread.
fn github_asks(root: &Path) {
    for _ in 0..MINTS_PER_PHASE {
        let root = root.to_owned();
        std::thread::spawn(move || {
            let line = json!({ "github_token": { "repo": "acme/widgets", "permissions": { "contents": "read" } } }).to_string();
            for _ in 0..50 {
                let socket = Paths::new(&root).at(crate::cloud::wire::AGENT_SOCKET);
                if let Ok(mut stream) = UnixStream::connect(socket) {
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(60)));
                    let _ = stream.write_all(format!("{line}\n").as_bytes());
                    let _ = BufReader::new(stream).read_line(&mut String::new());
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
    }
}

struct Profile {
    ticket_timeout: Duration,
    /// The session host's time to find its registration dead after a resume, and the wait after it.
    resume_detect: fn() -> Duration,
}

fn profile() -> Profile {
    match std::env::var("HARNESS_PROFILE").as_deref() {
        Ok("after") => Profile {
            ticket_timeout: Duration::from_secs(35),
            resume_detect: || Duration::from_secs(1).mul_f64(unit()),
        },
        _ => Profile {
            ticket_timeout: Duration::from_secs(10),
            resume_detect: || {
                Duration::from_secs(3)
                    + Duration::from_secs(1).mul_f64(unit())
                    + Duration::from_millis(100).mul_f64(unit())
            },
        },
    }
}

/// The session host's registration: asks for a ticket until one comes,
/// waiting the credential backoff after each failed ask. Returns the
/// number of failed asks.
fn register(root: &Path, profile: &Profile, deadline: Instant) -> u32 {
    let mut ceiling = Duration::from_secs(1);
    let mut failures = 0;
    let line = json!({ "carrier_ticket": {} }).to_string();
    // The agent's sockets come up with its worker: the model asks from then on.
    let paths = Paths::new(root);
    while !paths.at(crate::cloud::wire::AGENT_SOCKET).exists()
        && !paths.at("/run/cmux-vm-agent/carrier.sock").exists()
    {
        assert!(Instant::now() < deadline, "the agent's sockets did not come up");
        std::thread::sleep(Duration::from_millis(5));
    }
    loop {
        assert!(Instant::now() < deadline, "no registration within the harness deadline");
        let reply = ask_line(root, &line, CLI_WAIT.min(profile.ticket_timeout));
        if reply.as_ref().is_ok_and(|reply| reply["ok"] == true) {
            return failures;
        }
        failures += 1;
        std::thread::sleep(ceiling.mul_f64(unit()));
        ceiling = (ceiling * 2).min(Duration::from_secs(60));
    }
}

fn run_once(origin: &str, profile: &Profile) -> (Duration, u32, Duration, u32) {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    bound_machine(root);
    *TEST_ORIGIN.lock().unwrap() = Some(origin.to_owned());
    let layout = cmux_server_core::layout::layout(
        InstallMode::System,
        Platform::Linux,
        &cmux_server_core::layout::LayoutEnv::default(),
    )
    .unwrap();
    let ctx =
        RoleContext { instance_id: Some(INSTANCE.to_owned()), layout, mode: InstallMode::System };
    let mut role = CloudRole::new(Paths::new(root));
    let deadline = Instant::now() + Duration::from_secs(240);

    // Start: the agent and the session host start together.
    let started = Instant::now();
    github_asks(root);
    role.start(&ctx).unwrap();
    let start_failures = register(root, profile, deadline);
    let start = started.elapsed();

    // Let the start's mints and reports drain, then pause and resume.
    std::thread::sleep(Duration::from_secs(25));
    let resumed = Instant::now();
    github_asks(root);
    role.on_event(&HostEvent::Resumed).unwrap();
    std::thread::sleep((profile.resume_detect)());
    let resume_failures = register(root, profile, deadline);
    let resume = resumed.elapsed();

    let _ = role.stop(&StopContext { deadline: Instant::now() + Duration::from_secs(30) });
    (start, start_failures, resume, resume_failures)
}

fn summary(name: &str, mut times: Vec<Duration>, failed: &[u32]) -> String {
    times.sort();
    let p50 = times[times.len() / 2];
    let max = times[times.len() - 1];
    let with_failures = failed.iter().filter(|n| **n > 0).count();
    let all: Vec<String> = times.iter().map(|t| format!("{:.2}", t.as_secs_f64())).collect();
    format!(
        "{name}: p50 {:.2} s, max {:.2} s, runs with a failed ticket ask {with_failures}/{} (sorted s: {})",
        p50.as_secs_f64(),
        max.as_secs_f64(),
        times.len(),
        all.join(" ")
    )
}

#[test]
#[ignore = "before/after harness: about a minute a run; run on purpose"]
fn carrier_register_harness() {
    let runs: usize = std::env::var("HARNESS_RUNS").ok().and_then(|n| n.parse().ok()).unwrap_or(10);
    let profile = profile();
    let origin = platform();
    let (mut starts, mut start_failed, mut resumes, mut resume_failed) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for run in 0..runs {
        let (start, sf, resume, rf) = run_once(&origin, &profile);
        eprintln!(
            "HARNESS run {run}: start {:.2} s ({sf} failed asks), resume {:.2} s ({rf} failed asks)",
            start.as_secs_f64(),
            resume.as_secs_f64()
        );
        starts.push(start);
        start_failed.push(sf);
        resumes.push(resume);
        resume_failed.push(rf);
    }
    *TEST_ORIGIN.lock().unwrap() = None;
    let profile_name = std::env::var("HARNESS_PROFILE").unwrap_or_else(|_| "before".to_owned());
    eprintln!("HARNESS profile {profile_name}, {runs} runs");
    eprintln!("HARNESS {}", summary("start -> registered", starts, &start_failed));
    eprintln!("HARNESS {}", summary("resume -> registered", resumes, &resume_failed));
}
