//! The ticket thread against a fake Cloud API: an ask is answered on its own
//! socket, an ask before the bind waits for it, the bearer is minted at the
//! bind, and nothing in the journal carries a ticket.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::{CarrierServer, UNBOUND_WAIT};
use crate::cloud::client::{CloudClient, Http};
use crate::cloud::wire::{Bound, Env};

const DEV: &str = "https://cmux-api-development.debussy.workers.dev";
const INSTALL: &str = "inst_v0000000000000000004";
const MACHINE: &str = "vm_m0000000000000000004";
const T0: u64 = 1_790_000_000_000;
const TICKET: &str = "relay-ticket-0123456789";

#[derive(Default)]
struct State {
    urls: Vec<String>,
}

#[derive(Clone, Default)]
struct Fake(Arc<Mutex<State>>);

impl Fake {
    fn urls(&self) -> Vec<String> {
        self.0.lock().unwrap().urls.clone()
    }
}

impl Http for Fake {
    fn post(
        &self,
        url: &str,
        _body: &Value,
        _bearer: Option<&str>,
    ) -> Result<(u16, Value), String> {
        self.0.lock().unwrap().urls.push(url.to_owned());
        match url.strip_prefix(DEV).unwrap_or("") {
            "/v1/auth/challenge" => Ok((
                200,
                json!({ "install": INSTALL, "nonce": "n-1", "message_prefix": format!("cmux-auth-v1\ndevelopment\n{INSTALL}\n") }),
            )),
            "/v1/auth/token" => Ok((
                200,
                json!({ "access_token": "bearer-1", "token_type": "Bearer", "expires_at": T0 + 600_000, "install": INSTALL, "user": "user_u0000000000000000001", "grant": "grant_v000000000000000004", "team": "team_t0000000000000000001" }),
            )),
            _ => Ok((404, json!({}))),
        }
    }

    fn post_empty(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.0.lock().unwrap().urls.push(url.to_owned());
        assert_eq!(bearer, Some("bearer-1"));
        Ok((
            200,
            json!({ "ok": true, "value": { "relay": "relay+do://relay.example", "slot": "slot_0123456789abcdefghijkl", "ticket": TICKET, "expires_at": T0 + 60_000 } }),
        ))
    }
}

fn client(fake: &Fake) -> CloudClient<Fake> {
    let bound = Bound {
        machine: MACHINE.to_owned(),
        team: "team_t0000000000000000001".to_owned(),
        host: "host_h0000000000000000004".to_owned(),
        epoch: 1,
        install: INSTALL.to_owned(),
        user: "user_u0000000000000000001".to_owned(),
        grant: "grant_v000000000000000004".to_owned(),
        env: Env::Dev,
        api_origin: DEV.to_owned(),
        keyset: Value::Null,
        bound_at: T0,
    };
    let key = InstallKey::generate(&SystemRandom::new()).unwrap();
    CloudClient::new(fake.clone(), bound, key)
}

fn fixed_now() -> u64 {
    T0
}

static LOGGED: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn keep_log(line: &str) {
    LOGGED.lock().unwrap().push(line.to_owned());
}

fn serve(dir: &tempfile::TempDir) -> (CarrierServer<Fake>, std::path::PathBuf) {
    let path = dir.path().join("carrier.sock");
    let listener = UnixListener::bind(&path).unwrap();
    (CarrierServer::spawn(listener, fixed_now, keep_log).unwrap(), path)
}

fn ask(path: &std::path::Path, line: &str) -> Value {
    let mut stream = UnixStream::connect(path).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    stream.write_all(format!("{line}\n").as_bytes()).unwrap();
    let mut reply = String::new();
    BufReader::new(stream).read_line(&mut reply).unwrap();
    serde_json::from_str(&reply).unwrap()
}

/// Waits for the fake to have seen `n` requests (the bind's bearer mint runs on the thread).
fn wait_for_requests(fake: &Fake, n: usize) {
    let until = Instant::now() + Duration::from_secs(10);
    while fake.urls().len() < n {
        assert!(Instant::now() < until, "only {:?}", fake.urls());
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn a_bound_machine_answers_its_ticket_in_one_request_after_the_bearer_minted_at_the_bind() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    server.bound(client(&fake));
    wait_for_requests(&fake, 2);
    assert_eq!(fake.urls(), [format!("{DEV}/v1/auth/challenge"), format!("{DEV}/v1/auth/token")]);
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["ticket"], TICKET);
    let urls = fake.urls();
    assert_eq!(urls.len(), 3, "the ticket is one request: {urls:?}");
    assert_eq!(urls[2], format!("{DEV}/v1/cloud/machines/{MACHINE}/carrier"));
    let logged = LOGGED.lock().unwrap().clone();
    assert!(logged.iter().any(|l| l.starts_with("carrier ticket: issued in ")), "{logged:?}");
    assert!(logged.iter().all(|l| !l.contains(TICKET)));
    drop(server);
}

#[test]
fn an_ask_before_the_bind_is_answered_once_the_bind_lands() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    let asking = std::thread::spawn(move || ask(&path, r#"{"carrier_ticket": {}}"#));
    std::thread::sleep(Duration::from_millis(200));
    let bound_at = Instant::now();
    server.bound(client(&fake));
    let reply = asking.join().unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(bound_at.elapsed() < Duration::from_secs(5), "the ask did not wait out a backoff");
    drop(server);
}

#[test]
fn an_unbound_machine_refuses_within_the_ticket_command_timeout() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let started = Instant::now();
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["error"]["code"], "vm.unbound");
    assert!(started.elapsed() >= UNBOUND_WAIT);
    assert!(started.elapsed() < Duration::from_secs(10), "past the session host's 10 s");
    drop(server);
}

#[test]
fn any_other_line_is_refused_without_a_request() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    server.bound(client(&fake));
    wait_for_requests(&fake, 2);
    assert_eq!(ask(&path, r#"{"github_token": {}}"#)["error"]["code"], "request.invalid");
    assert_eq!(
        ask(&path, r#"{"carrier_ticket": {"slot": "x"}}"#)["error"]["code"],
        "request.invalid"
    );
    assert_eq!(fake.urls().len(), 2);
    drop(server);
}

#[test]
fn dropping_the_server_ends_an_ask_waiting_for_the_bind() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let asking = std::thread::spawn(move || ask(&path, r#"{"carrier_ticket": {}}"#));
    std::thread::sleep(Duration::from_millis(200));
    let started = Instant::now();
    drop(server);
    assert!(started.elapsed() < Duration::from_secs(2), "the stop waited out the bind wait");
    assert_eq!(asking.join().unwrap()["error"]["code"], "vm.agent_stopping");
}
