//! The ticket thread against a fake Cloud API: an ask is answered on its own
//! socket, an ask before the bind waits for it, the bearer is minted at the
//! bind, and nothing in the journal carries a ticket. A carrier bind keeps
//! a ticket for the Register, refreshed before it expires and fresh after a
//! resume, and a ticket asks never wait on a GitHub mint in flight.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::{CarrierServer, Hooks, MAX_REFRESHES, Resumes, UNBOUND_WAIT};
use crate::cloud::client::{CloudClient, Http};
use crate::cloud::github_minter::Stop;
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
    client_with(fake.clone())
}

fn client_with<H: Http>(http: H) -> CloudClient<H> {
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
    CloudClient::new(http, bound, key)
}

fn fixed_now() -> u64 {
    T0
}

static LOGGED: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn keep_log(line: &str) {
    LOGGED.lock().unwrap().push(line.to_owned());
}

fn serve(dir: &tempfile::TempDir) -> (CarrierServer<Fake>, std::path::PathBuf) {
    serve_with(dir, Arc::default())
}

fn wall_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

fn quiet(_: &str) {}

fn serve_with<H: Http + Send + 'static>(
    dir: &tempfile::TempDir,
    stop: Arc<Stop>,
) -> (CarrierServer<H>, std::path::PathBuf) {
    let path = dir.path().join("carrier.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let hooks = Hooks { now: fixed_now, log: keep_log, ask_wait: super::ASK_WAIT };
    (CarrierServer::spawn(listener, hooks, stop, Arc::default()).unwrap(), path)
}

/// A fake whose ticket route says it was reached, then waits for the test to release it.
struct Gated {
    inner: Fake,
    entered: Mutex<std::sync::mpsc::Sender<()>>,
    gate: Mutex<std::sync::mpsc::Receiver<()>>,
}

impl Http for Gated {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.inner.post(url, body, bearer)
    }

    fn post_empty(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        let _ = self.entered.lock().unwrap().send(());
        let _ = self.gate.lock().unwrap().recv();
        self.inner.post_empty(url, bearer)
    }
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
    server.bound(client(&fake), false);
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

/// The bind answer's ticket for the session host's first Register.
fn bind_ticket(ticket: &str, life_s: u64) -> Value {
    json!({ "ok": true, "relay": "relay+do://relay.example", "slot": "slot_0123456789abcdefghijkl", "ticket": ticket, "expires_at": T0 / 1000 + life_s })
}

#[test]
fn a_ticket_from_the_bind_goes_to_the_first_register_with_no_ticket_request() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    server.bound_with_ticket(
        client(&fake),
        true,
        Some((server.bind_generation(), bind_ticket("bind-ticket-0123", 300))),
    );
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!((&reply["ok"], &reply["ticket"]), (&json!(true), &json!("bind-ticket-0123")));
    wait_for_requests(&fake, 2);
    // Dropping the server joins its request threads: the bind's request minted
    // the bearer (for later tickets) and asked for no ticket.
    drop(server);
    assert_eq!(fake.urls(), [format!("{DEV}/v1/auth/challenge"), format!("{DEV}/v1/auth/token")]);
    let logged = LOGGED.lock().unwrap().clone();
    assert!(logged.iter().any(|l| l == "carrier ticket: kept from the bind"), "{logged:?}");
    assert!(logged.iter().all(|l| !l.contains("bind-ticket-0123")), "{logged:?}");
}

#[test]
fn a_resume_before_the_bind_request_does_not_invalidate_its_answer() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    server.resumes.note();
    let before = server.bind_generation();
    server.bound_with_ticket(client(&fake), true, Some((before, bind_ticket("after-resume", 300))));
    assert_eq!(ask(&path, r#"{"carrier_ticket": {}}"#)["ticket"], "after-resume");
    wait_for_requests(&fake, 2);
    drop(server);
    assert_eq!(fake.urls().len(), 2, "only the bearer was requested");
}

/// The bind HTTP answer can arrive before the role notes a resume, while
/// installation of that answer on the ticket threads happens after it.
#[test]
fn a_resume_between_the_bind_answer_and_install_drops_the_ticket() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    let before = server.bind_generation();
    let answer = bind_ticket("before-resume", 300);
    server.resumes.note();
    server.bound_with_ticket(client(&fake), true, Some((before, answer)));
    let state = server.shared.lock();
    assert!(
        state.warm.as_ref().is_none_or(|warm| warm.reply["ticket"] != "before-resume"),
        "a bind answer from before resume was kept"
    );
    drop(state);
    wait_for("a replacement prefetched before Register", || server.shared.lock().warm.is_some());
    assert_eq!(ask(&path, r#"{"carrier_ticket": {}}"#)["ticket"], TICKET);
}

#[test]
fn a_bind_ticket_too_close_to_expiry_or_on_a_machine_without_a_carrier_is_not_kept() {
    // Too close to its expiry to keep: the bind asks for a ticket as before.
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    server.bound_with_ticket(
        client(&fake),
        true,
        Some((server.bind_generation(), bind_ticket("short-lived-0123", 30))),
    );
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ticket"], TICKET);
    drop(server);
    assert!(fake.urls().contains(&format!("{DEV}/v1/cloud/machines/{MACHINE}/carrier")));
    // No carrier: nothing is kept, and nothing is asked ahead.
    let dir = tempfile::tempdir().unwrap();
    let (server, _path) = serve(&dir);
    let fake = Fake::default();
    server.bound_with_ticket(
        client(&fake),
        false,
        Some((server.bind_generation(), bind_ticket("no-carrier-0123", 300))),
    );
    drop(server);
    assert!(fake.urls().iter().all(|u| !u.ends_with("/carrier")), "{:?}", fake.urls());
}

#[test]
fn an_ask_before_the_bind_is_answered_once_the_bind_lands() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    let asking = std::thread::spawn(move || ask(&path, r#"{"carrier_ticket": {}}"#));
    std::thread::sleep(Duration::from_millis(200));
    let bound_at = Instant::now();
    server.bound(client(&fake), false);
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
    // The refusal's journal line has its own token, its code and its message.
    let logged = LOGGED.lock().unwrap().clone();
    assert!(
        logged.iter().any(|l| l.starts_with("carrier ticket: refused vm.unbound in ") && l.contains(" ms: ")),
        "{logged:?}"
    );
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "past the 10 s an older session host waits"
    );
    drop(server);
}

/// Every success reads `<what> in N ms`, every refusal `refused <code> ...`
/// with its message on one line: a journal reader tells them apart by the
/// token alone, and no line carries the ticket.
#[test]
fn a_refusal_line_has_its_own_token_and_a_success_line_never_has_it() {
    let issued = json!({ "ok": true, "ticket": TICKET, "expires_at": T0 + 60_000 });
    assert_eq!(
        super::outcome_line(&issued, "prefetched", "", 893),
        "carrier ticket: prefetched in 893 ms"
    );
    assert_eq!(
        super::outcome_line(&issued, "issued", " (kept)", 776),
        "carrier ticket: issued (kept) in 776 ms"
    );
    let slow = json!({ "ok": false, "error": { "code": "carrier.slow", "message": "the ticket\nis slow" } });
    assert_eq!(
        super::outcome_line(&slow, "fetched for an ask", " (kept)", 25_000),
        "carrier ticket: refused carrier.slow (kept) in 25000 ms: the ticket is slow"
    );
    let bare = json!({ "ok": false });
    assert_eq!(
        super::outcome_line(&bare, "refreshed", "", 4),
        "carrier ticket: refused unknown in 4 ms"
    );
    let long =
        json!({ "ok": false, "error": { "code": "auth.refused", "message": "x".repeat(1000) } });
    let line = super::outcome_line(&long, "issued", "", 1);
    assert!(line.len() < 300, "{line}");
    for line in [
        super::outcome_line(&issued, "prefetched", "", 1),
        super::outcome_line(&issued, "issued", "", 1),
    ] {
        assert!(!line.contains("refused") && !line.contains(TICKET), "{line}");
    }
}

#[test]
fn any_other_line_is_refused_without_a_request() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    server.bound(client(&fake), false);
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

#[test]
fn a_stop_from_the_role_withholds_a_ticket_minted_in_flight() {
    // The role sets its stop before it asks the worker to end; a worker stuck past the deadline has not dropped
    // this server yet, and the ticket of a mint in flight must not go out.
    let (release, gate) = std::sync::mpsc::channel();
    let (entered, reached) = std::sync::mpsc::channel();
    let http =
        Gated { inner: Fake::default(), entered: Mutex::new(entered), gate: Mutex::new(gate) };
    let dir = tempfile::tempdir().unwrap();
    let stop = Arc::new(Stop::default());
    let (server, path) = serve_with(&dir, Arc::clone(&stop));
    server.bound(client_with(http), false);
    let asking = std::thread::spawn(move || ask(&path, r#"{"carrier_ticket": {}}"#));
    reached.recv_timeout(Duration::from_secs(10)).unwrap();
    stop.set();
    release.send(()).unwrap();
    let reply = asking.join().unwrap();
    assert_eq!(reply["error"]["code"], "vm.agent_stopping", "{reply}");
    assert!(!reply.to_string().contains(TICKET));
    // A later ask gets no ticket either.
    let path = dir.path().join("carrier.sock");
    assert_eq!(ask(&path, r#"{"carrier_ticket": {}}"#)["error"]["code"], "vm.agent_stopping");
    drop(server);
}

#[test]
fn a_client_dripping_its_line_is_cut_off_at_the_line_wait() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path) = serve(&dir);
    let fake = Fake::default();
    server.bound(client(&fake), false);
    wait_for_requests(&fake, 2);
    let mut drip = UnixStream::connect(&path).unwrap();
    let started = Instant::now();
    let dripping = std::thread::spawn(move || {
        for byte in br#"{"carrier_ticket": {}}"# {
            if drip.write_all(&[*byte]).is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(300));
        }
    });
    std::thread::sleep(Duration::from_millis(100));
    // The next asker is answered once the dripping one is cut off, well before it would have finished (6.6 s).
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(started.elapsed() < Duration::from_secs(4), "waited {:?}", started.elapsed());
    dripping.join().unwrap();
    drop(server);
}

/// A Cloud API on the wall clock: each ticket is `t-N`, good for `life_s`
/// seconds from when it was asked for. Counts transport resets.
#[derive(Default)]
struct Live {
    life_s: u64,
    tickets: Mutex<u64>,
    resets: Mutex<u64>,
    /// While set, a GitHub token mint is held here (the head-of-line case).
    mint_gate: Mutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
    /// While set, a bearer mint is held here (a slow auth at the bind).
    token_gate: Mutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
    /// Each ticket request takes the next gate here, in order, and is held
    /// on it up to 20 s (one on a pooled connection that died in a pause).
    ticket_gates: Mutex<
        std::collections::VecDeque<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>,
    >,
    /// Ticket requests that came back.
    answered: Mutex<u64>,
}

impl Live {
    fn tickets(&self) -> u64 {
        *self.tickets.lock().unwrap()
    }
}

#[derive(Clone)]
struct LiveHttp(Arc<Live>);

impl Http for LiveHttp {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        if url.ends_with(crate::cloud::github::TOKEN_PATH) {
            if let Some((entered, gate)) = self.0.mint_gate.lock().unwrap().as_ref() {
                let _ = entered.send(());
                let _ = gate.recv_timeout(Duration::from_secs(20));
            }
            return Ok((503, json!({})));
        }
        if url.ends_with("/v1/auth/token")
            && let Some((entered, gate)) = self.0.token_gate.lock().unwrap().as_ref()
        {
            let _ = entered.send(());
            let _ = gate.recv_timeout(Duration::from_secs(20));
        }
        if url.ends_with("/v1/auth/token") {
            // A bearer good for 10 minutes on the wall clock, so it is minted once.
            return Ok((
                200,
                json!({ "access_token": "bearer-1", "token_type": "Bearer", "expires_at": wall_now() + 600_000, "install": INSTALL, "user": "user_u0000000000000000001", "grant": "grant_v000000000000000004", "team": "team_t0000000000000000001" }),
            ));
        }
        Fake::default().post(url, body, bearer)
    }

    fn post_empty(&self, _url: &str, _bearer: Option<&str>) -> Result<(u16, Value), String> {
        let n = {
            let mut tickets = self.0.tickets.lock().unwrap();
            *tickets += 1;
            *tickets
        };
        let gate = self.0.ticket_gates.lock().unwrap().pop_front();
        if let Some((entered, gate)) = gate {
            let _ = entered.send(());
            let _ = gate.recv_timeout(Duration::from_secs(20));
        }
        *self.0.answered.lock().unwrap() += 1;
        Ok((
            200,
            json!({ "ok": true, "value": { "relay": "relay+do://relay.example", "slot": "slot_0123456789abcdefghijkl", "ticket": format!("t-{n}"), "expires_at": wall_now() / 1000 + self.0.life_s } }),
        ))
    }

    fn reset(&self) {
        *self.0.resets.lock().unwrap() += 1;
    }

    fn fresh(&self) -> Option<Self> {
        Some(self.clone())
    }
}

fn live_server(
    dir: &tempfile::TempDir,
    life_s: u64,
    ask_wait: Duration,
) -> (CarrierServer<LiveHttp>, std::path::PathBuf, Arc<Live>, Arc<Resumes>) {
    let path = dir.path().join("carrier.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let resumes = Arc::new(Resumes::default());
    let hooks = Hooks { now: wall_now, log: quiet, ask_wait };
    let server =
        CarrierServer::spawn(listener, hooks, Arc::default(), Arc::clone(&resumes)).unwrap();
    let live = Arc::new(Live { life_s, ..Live::default() });
    (server, path, live, resumes)
}

fn wait_for(what: &str, mut ok: impl FnMut() -> bool) {
    let until = Instant::now() + Duration::from_secs(15);
    while !ok() {
        assert!(Instant::now() < until, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_carrier_bind_keeps_a_ticket_and_the_register_reads_it_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, _resumes) = live_server(&dir, 300, super::ASK_WAIT);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the ticket asked for at the bind", || live.tickets() == 1);
    let started = Instant::now();
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ticket"], "t-1", "{reply}");
    assert!(started.elapsed() < Duration::from_secs(1));
    assert_eq!(live.tickets(), 1, "the Register read the kept ticket: no request");
    // A handed-out ticket is not kept: the next ask (a failed Register) gets a new one.
    assert_eq!(ask(&path, r#"{"carrier_ticket": {}}"#)["ticket"], "t-2");
    drop(server);
}

#[test]
fn a_bind_without_a_carrier_asks_for_no_ticket_ahead() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, _resumes) = live_server(&dir, 300, super::ASK_WAIT);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), false);
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(live.tickets(), 0);
    assert_eq!(ask(&path, r#"{"carrier_ticket": {}}"#)["ticket"], "t-1");
    drop(server);
}

/// Tickets good for 62 s are refreshed 60 s before they expire, so about
/// every 2 s here; an unused one is refreshed MAX_REFRESHES times, then
/// lapses and the thread has no timer left.
#[test]
fn an_unused_kept_ticket_is_refreshed_before_it_expires_then_lapses() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, _resumes) = live_server(&dir, 62, super::ASK_WAIT);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the first refresh", || live.tickets() == 2);
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ticket"], "t-2", "the refreshed ticket is the kept one: {reply}");
    drop(server);

    let dir = tempfile::tempdir().unwrap();
    let (server, _path, live, _resumes) = live_server(&dir, 62, super::ASK_WAIT);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    let all = 1 + u64::from(MAX_REFRESHES);
    wait_for("every refresh", || live.tickets() == all);
    std::thread::sleep(Duration::from_secs(3));
    assert_eq!(live.tickets(), all, "no refresh after the last one");
    drop(server);
}

#[test]
fn a_resume_drops_the_kept_ticket_and_keeps_a_fresh_one_on_a_new_connection() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, resumes) = live_server(&dir, 300, super::ASK_WAIT);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the ticket asked for at the bind", || live.tickets() == 1);
    resumes.note();
    wait_for("the ticket asked for at the resume", || live.tickets() == 2);
    assert_eq!(*live.resets.lock().unwrap(), 1, "the pooled connection is from before the pause");
    let started = Instant::now();
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ticket"], "t-2", "{reply}");
    assert!(started.elapsed() < Duration::from_secs(1));
    assert_eq!(live.tickets(), 2);
    drop(server);
}

/// The head-of-line case: the GitHub minter (the worker's queue) is inside a
/// slow mint, and the ticket ask is still answered at once.
#[test]
fn a_ticket_ask_is_answered_while_a_github_mint_is_in_flight() {
    use crate::cloud::github::TokenAsk;
    use crate::cloud::github_minter::Minter;

    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, _resumes) = live_server(&dir, 300, super::ASK_WAIT);
    let (entered, reached) = std::sync::mpsc::channel();
    let (release, gate) = std::sync::mpsc::channel();
    let stop = Arc::new(Stop::default());
    let minter: Minter<LiveHttp> = Minter::spawn(wall_now, quiet, Arc::clone(&stop)).unwrap();
    minter.bound(client_with(LiveHttp(Arc::clone(&live))));
    server.bound(client_with(LiveHttp(Arc::clone(&live))), false);
    // The gate is set after the minter's bind: only the mint below waits on it.
    *live.mint_gate.lock().unwrap() = Some((entered, gate));
    let (ours, theirs) = UnixStream::pair().unwrap();
    let mint =
        TokenAsk { repo: "acme/widgets".into(), permissions: Default::default(), label: None };
    minter.ask(Ok::<_, String>(mint), theirs);
    reached.recv_timeout(Duration::from_secs(10)).expect("the mint did not start");
    let started = Instant::now();
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(started.elapsed() < Duration::from_secs(1), "waited {:?}", started.elapsed());
    release.send(()).unwrap();
    drop(ours);
    drop(minter);
    drop(server);
}

/// #38291's review follow-up (F1): a bearer mint at the bind that takes
/// longer than the ask may wait. The ask gets a `carrier.slow` line within
/// the ask wait instead of running past the session host's command, and the
/// ticket asked for once the mint lands is kept for the next ask.
#[test]
fn a_slow_bearer_mint_at_the_bind_answers_the_ask_within_its_wait_and_keeps_the_ticket() {
    let dir = tempfile::tempdir().unwrap();
    let ask_wait = Duration::from_secs(1);
    let (server, path, live, _resumes) = live_server(&dir, 300, ask_wait);
    let (entered, reached) = std::sync::mpsc::channel();
    let (release, gate) = std::sync::mpsc::channel();
    *live.token_gate.lock().unwrap() = Some((entered, gate));
    let asking = {
        let path = path.clone();
        std::thread::spawn(move || {
            let started = Instant::now();
            (ask(&path, r#"{"carrier_ticket": {}}"#), started.elapsed())
        })
    };
    std::thread::sleep(Duration::from_millis(100));
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    reached.recv_timeout(Duration::from_secs(10)).expect("the bind did not mint at once");
    let (reply, took) = asking.join().unwrap();
    assert_eq!(reply["error"]["code"], "carrier.slow", "{reply}");
    assert!(took < ask_wait + Duration::from_secs(1), "waited {took:?}");
    release.send(()).unwrap();
    wait_for("the ticket asked for after the mint", || live.tickets() == 1);
    let started = Instant::now();
    assert_eq!(ask(&path, r#"{"carrier_ticket": {}}"#)["ticket"], "t-1");
    assert!(started.elapsed() < Duration::from_secs(1));
    drop(server);
}

/// #38329's review (P2): a ticket asked for an ask is good while it may be
/// handed out (HAND_OUT_MARGIN, 30 s), not only past the kept ticket's
/// refresh point (REFRESH_BEFORE, 60 s). A 45 s ticket goes to the asker on
/// the first fetch, with one request and no `carrier.slow`.
#[test]
fn a_45_s_ticket_asked_for_an_ask_is_handed_out_on_the_first_fetch() {
    let dir = tempfile::tempdir().unwrap();
    let ask_wait = Duration::from_secs(3);
    let (server, path, live, _resumes) = live_server(&dir, 45, ask_wait);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), false);
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["ticket"], "t-1", "{reply}");
    assert_eq!(live.tickets(), 1, "the ticket asked for the ask was thrown away and asked again");
    drop(server);
}

/// Holds the next ticket request (a slow one, up to 20 s) until the returned
/// sender is dropped or sends; the receiver says it started.
fn hold_next_ticket(live: &Live) -> (std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>) {
    let (entered, reached) = std::sync::mpsc::channel();
    let (release, gate) = std::sync::mpsc::channel();
    live.ticket_gates.lock().unwrap().push_back((entered, gate));
    (release, reached)
}

/// #38329's review (F1): the ticket asked for at the bind hangs (a pooled
/// connection that died in the pause, 20 s to its bound) when the machine
/// resumes. The resume does not wait for it: a fresh ticket is asked for on a
/// transport of its own, the first ask after the resume gets it well inside
/// the ask wait, and the late reply from before the pause is never handed
/// out.
#[test]
fn a_resume_during_a_slow_ticket_fetch_asks_again_at_once_and_drops_the_late_reply() {
    let dir = tempfile::tempdir().unwrap();
    let ask_wait = Duration::from_secs(5);
    let (server, path, live, resumes) = live_server(&dir, 300, ask_wait);
    let (release, reached) = hold_next_ticket(&live);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    reached.recv_timeout(Duration::from_secs(10)).expect("the bind did not ask for a ticket");
    resumes.note();
    let started = Instant::now();
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    let took = started.elapsed();
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["ticket"], "t-2", "the ticket asked for after the resume: {reply}");
    assert!(
        took < Duration::from_secs(2),
        "waited {took:?} behind the fetch from before the pause"
    );
    // The fetch from before the pause comes back late; its ticket is dropped.
    release.send(()).unwrap();
    wait_for("the late reply", || *live.answered.lock().unwrap() == 2);
    std::thread::sleep(Duration::from_millis(100));
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_ne!(reply["ticket"], "t-1", "the ticket from before the pause was handed out");
    drop(server);
}

/// The earlier follow-up, folded into F1: a ticket asked for an ask before a
/// resume is not handed out after it. The asker waiting on it gets the
/// ticket asked for after the resume instead, inside its wait.
#[test]
fn a_ticket_asked_for_an_ask_before_a_resume_is_not_handed_out_after_it() {
    let dir = tempfile::tempdir().unwrap();
    let ask_wait = Duration::from_secs(5);
    let (server, path, live, resumes) = live_server(&dir, 300, ask_wait);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), false);
    let (release, reached) = hold_next_ticket(&live);
    let asking = {
        let path = path.clone();
        std::thread::spawn(move || {
            let started = Instant::now();
            (ask(&path, r#"{"carrier_ticket": {}}"#), started.elapsed())
        })
    };
    reached.recv_timeout(Duration::from_secs(10)).expect("the ask did not ask for a ticket");
    resumes.note();
    let (reply, took) = asking.join().unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["ticket"], "t-2", "the ticket asked for after the resume: {reply}");
    assert!(
        took < Duration::from_secs(2),
        "waited {took:?} behind the fetch from before the pause"
    );
    release.send(()).unwrap();
    wait_for("the late reply", || *live.answered.lock().unwrap() == 2);
    std::thread::sleep(Duration::from_millis(100));
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_ne!(reply["ticket"], "t-1", "the ticket from before the pause was handed out");
    drop(server);
}

/// Waits for `ok` up to `limit`; whether it held.
fn holds_within(limit: Duration, mut ok: impl FnMut() -> bool) -> bool {
    let until = Instant::now() + limit;
    while !ok() {
        if Instant::now() >= until {
            return false;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    true
}

/// #38593's review (F1): a resume that lands right before the hand-out
/// (after the socket thread took the kept ticket and checked it) does not
/// let that ticket out. The ask gets the ticket asked for after the resume.
#[test]
fn a_resume_right_before_the_hand_out_does_not_hand_out_the_old_ticket() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, resumes) = live_server(&dir, 300, Duration::from_secs(5));
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the kept ticket", || server.shared.lock().warm.is_some());
    let shared = Arc::clone(&server.shared);
    let resuming = Arc::clone(&resumes);
    *server.shared.test_points.before_handout.lock().unwrap() = Some(Box::new(move || {
        let before = shared.lock().generation;
        resuming.note();
        assert_ne!(shared.lock().generation, before, "the note starts the resume's generation");
    }));
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_ne!(reply["ticket"], "t-1", "the ticket from before the resume was handed out");
    assert_eq!(reply["ticket"], "t-2", "{reply}");
    drop(server);
}

/// #38593's review (F1): an ask between `bound()` and the fetch thread
/// taking the bind does not get the kept ticket of the bind before it.
#[test]
fn an_ask_before_the_fetch_thread_takes_a_rebind_does_not_get_the_old_ticket() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, _resumes) = live_server(&dir, 300, Duration::from_secs(5));
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the kept ticket", || server.shared.lock().warm.is_some());
    let (release, gate) = std::sync::mpsc::channel();
    *server.shared.test_points.hold_fetcher.lock().unwrap() = Some(gate);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the fetch thread held", || {
        server.shared.test_points.hold_fetcher.lock().unwrap().is_none()
    });
    let asking = std::thread::spawn(move || ask(&path, r#"{"carrier_ticket": {}}"#));
    std::thread::sleep(Duration::from_millis(200));
    release.send(()).unwrap();
    let reply = asking.join().unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    assert_ne!(reply["ticket"], "t-1", "the ticket of the bind before was handed out");
    drop(server);
}

/// #38593's review (F2): between the fetch thread taking an asker's want and
/// starting its request, the asker woken again (another ask, any wake) does
/// not ask a second time: one ask is one ticket request.
#[test]
fn an_asker_woken_before_its_request_starts_causes_one_request() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, _resumes) = live_server(&dir, 300, Duration::from_secs(5));
    server.bound(client_with(LiveHttp(Arc::clone(&live))), false);
    wait_for("the bind", || {
        let state = server.shared.lock();
        state.bound && !state.fetching
    });
    let shared = Arc::clone(&server.shared);
    *server.shared.test_points.before_wanted.lock().unwrap() = Some(Box::new(move || {
        shared.changed.notify_all();
        let _ = holds_within(Duration::from_millis(500), || shared.lock().want);
    }));
    let reply = ask(&path, r#"{"carrier_ticket": {}}"#);
    assert_eq!(reply["ticket"], "t-1", "{reply}");
    assert!(
        !holds_within(Duration::from_millis(500), || live.tickets() > 1),
        "the one ask asked for {} tickets",
        live.tickets()
    );
    drop(server);
}

/// #38700's review (F1): a rebind between the fetch thread taking an
/// asker's want and starting its request. That request (on the old client)
/// is of the generation before the rebind: its late reply is dropped, never
/// handed out, while the new bind's ticket is still on its way.
#[test]
fn a_rebind_before_a_wanted_request_starts_drops_that_requests_late_reply() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, _resumes) = live_server(&dir, 300, Duration::from_secs(10));
    server.bound(client_with(LiveHttp(Arc::clone(&live))), false);
    wait_for("the bind", || {
        let state = server.shared.lock();
        state.bound && !state.fetching
    });
    // The old client's ticket request (t-1) and the new bind's (t-2) are each held.
    let (release_old, old_entered) = hold_next_ticket(&live);
    let (release_new, new_entered) = hold_next_ticket(&live);
    let (at_wanted, reached_wanted) = std::sync::mpsc::channel();
    let (go, gate) = std::sync::mpsc::channel::<()>();
    *server.shared.test_points.before_wanted.lock().unwrap() = Some(Box::new(move || {
        let _ = at_wanted.send(());
        let _ = gate.recv_timeout(Duration::from_secs(10));
    }));
    let asking = std::thread::spawn(move || ask(&path, r#"{"carrier_ticket": {}}"#));
    reached_wanted.recv_timeout(Duration::from_secs(10)).expect("the ask's want was not taken");
    server.bound(client_with(LiveHttp(Arc::clone(&live))), false);
    go.send(()).unwrap();
    old_entered.recv_timeout(Duration::from_secs(10)).expect("the old request did not start");
    new_entered.recv_timeout(Duration::from_secs(10)).expect("the new bind did not ask");
    // The old request comes back while the new bind's is in flight.
    release_old.send(()).unwrap();
    std::thread::sleep(Duration::from_millis(200));
    release_new.send(()).unwrap();
    let reply = asking.join().unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    assert_ne!(reply["ticket"], "t-1", "the old binding's ticket was handed out");
    assert_eq!(reply["ticket"], "t-2", "{reply}");
    drop(server);
}

/// #38700's review (F1): a Register between `bound()` and the fetch thread
/// taking the bind sets the want; the bind's prefetched ticket satisfies it.
/// No second ticket request follows, and no extra reply waits for the next
/// Register.
#[test]
fn a_want_satisfied_by_the_binds_prefetched_ticket_asks_for_no_more() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, _resumes) = live_server(&dir, 300, Duration::from_secs(5));
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the kept ticket", || live.tickets() == 1 && server.shared.lock().warm.is_some());
    let (release, gate) = std::sync::mpsc::channel();
    *server.shared.test_points.hold_fetcher.lock().unwrap() = Some(gate);
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the fetch thread held", || {
        server.shared.test_points.hold_fetcher.lock().unwrap().is_none()
    });
    let asking = std::thread::spawn(move || ask(&path, r#"{"carrier_ticket": {}}"#));
    std::thread::sleep(Duration::from_millis(200));
    release.send(()).unwrap();
    let reply = asking.join().unwrap();
    assert_eq!(reply["ticket"], "t-2", "the rebind's prefetched ticket: {reply}");
    assert!(
        !holds_within(Duration::from_millis(500), || live.tickets() > 2),
        "the Register's want asked for {} tickets in all (2 expected)",
        live.tickets()
    );
    drop(server);
}

/// #38700's review (F2): a Register right after a resume is noted, before
/// the fetch thread sees it, does not get the kept ticket from before the
/// resume.
#[test]
fn a_register_right_after_a_resume_is_noted_does_not_get_the_old_ticket() {
    let dir = tempfile::tempdir().unwrap();
    let (server, path, live, resumes) = live_server(&dir, 300, Duration::from_secs(5));
    server.bound(client_with(LiveHttp(Arc::clone(&live))), true);
    wait_for("the kept ticket", || server.shared.lock().warm.is_some());
    let (release, gate) = std::sync::mpsc::channel();
    *server.shared.test_points.hold_fetcher.lock().unwrap() = Some(gate);
    resumes.note();
    wait_for("the fetch thread held", || {
        server.shared.test_points.hold_fetcher.lock().unwrap().is_none()
    });
    let asking = std::thread::spawn(move || ask(&path, r#"{"carrier_ticket": {}}"#));
    std::thread::sleep(Duration::from_millis(200));
    release.send(()).unwrap();
    let reply = asking.join().unwrap();
    assert_eq!(reply["ok"], true, "{reply}");
    assert_ne!(reply["ticket"], "t-1", "the ticket from before the resume was handed out");
    drop(server);
}

/// A resume can be noted while a seeded bind is still waiting for the fetch
/// thread. The bind's ticket is stale as soon as the resume is noted, so the
/// fetcher must keep the pending resume and prefetch a fresh ticket before the
/// Register ask is answered. The wanted-request gate makes the before/after
/// Register wait visible in this same harness.
#[test]
fn a_resume_before_a_seeded_bind_is_handled_prefetches_for_register() {
    let dir = tempfile::tempdir().unwrap();
    let ask_wait = Duration::from_secs(5);
    let (server, path, live, resumes) = live_server(&dir, 300, ask_wait);
    let (wanted_signal, wanted_started) = std::sync::mpsc::channel();
    let (_release_wanted, wanted_gate) = std::sync::mpsc::channel::<()>();
    *server.shared.test_points.before_wanted.lock().unwrap() = Some(Box::new(move || {
        let _ = wanted_signal.send(());
        // The old ordering reaches a wanted request here. Keep it slow enough
        // for the measured before/after Register wait to be visible.
        let _ = wanted_gate.recv_timeout(Duration::from_secs(1));
    }));

    let (release_fetcher, fetcher_gate) = std::sync::mpsc::channel();
    *server.shared.test_points.hold_fetcher.lock().unwrap() = Some(fetcher_gate);
    server.bound_with_ticket(
        client_with(LiveHttp(Arc::clone(&live))),
        true,
        Some((
            server.bind_generation(),
            json!({
                "ok": true,
                "relay": "relay+do://relay.example",
                "slot": "slot_0123456789abcdefghijkl",
                "ticket": "stale-after-resume",
                "expires_at": wall_now() / 1000 + 300,
            }),
        )),
    );
    wait_for("the fetcher held before the seeded bind", || {
        server.shared.test_points.hold_fetcher.lock().unwrap().is_none()
    });
    resumes.note();

    let asking = {
        let path = path.clone();
        std::thread::spawn(move || {
            let started = Instant::now();
            (ask(&path, r#"{"carrier_ticket": {}}"#), started.elapsed())
        })
    };
    release_fetcher.send(()).unwrap();
    let (reply, took) = asking.join().unwrap();
    eprintln!("reconnect Register wait: {took:?}");
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["ticket"], "t-1", "{reply}");
    assert!(wanted_started.try_recv().is_err(), "Register asked for a ticket after reconnect");
    assert!(took < Duration::from_secs(1), "Register waited {took:?} behind the seeded bind");
    drop(server);
}

/// #38700's review: a model of the ticket threads on their one state.
/// Each seed drives a random interleaving of Registers (an ask, its
/// hand-out, an asker leaving), resumes, binds, the fetch thread's jobs,
/// request replies and the clock, every step one transition of
/// [`super::state::Core`], and checks after each step:
///
/// - no ticket asked for in an older generation is handed out;
/// - one request per want: no more `Wanted` requests than wants, and none
///   while a kept or answered ticket already satisfies the want;
/// - at most one request of the current generation is on its way;
/// - no ticket asked for on an older binding's client is handed out;
/// - a resume acts only on the latest binding's client: one picked before a
///   bind and acted on after it neither resumes nor asks on the old one.
///
/// The fetch thread's own clients (the bound one, the spare a request
/// leaves behind when the transport can make one, and a resume that waits
/// for a client) are modelled as `Hands`, with the spare failing at random,
/// so a resume can find no client and a bind can land before the request
/// it waits for comes back. A job that acts on a resume (`Job::Resume`, or
/// a `Job::Done` that a waiting resume takes) is acted on in a later step
/// than its pick, as the fetch thread acts on it after the lock is
/// released, so binds and resumes land in between.
mod model {
    use std::time::{Duration, Instant};

    use serde_json::{Value, json};

    use super::super::MAX_REFRESHES;
    use super::super::state::{Asked, Back, Core, Done, Hands, Job, Task, Warm};

    const SEEDS: u64 = 3000;
    const STEPS: usize = 250;
    const START_MS: u64 = 1_790_000_000_000;

    struct Rng(u64);

    impl Rng {
        fn below(&mut self, n: u64) -> u64 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.0 = x;
            x % n
        }
    }

    struct Bind {
        binding: u64,
        prefetch: bool,
        /// A ticket was actually supplied, independently of later invalidation.
        seeded: bool,
    }

    struct Request {
        generation: u64,
        /// The binding whose client the request runs on.
        binding: u64,
        task: Task,
    }

    /// A reply between its ask and its hand-out.
    struct Pending {
        reply: Value,
        kept: bool,
        generation: u64,
        started: Instant,
    }

    struct Model {
        core: Core<Bind, u64>,
        now_ms: u64,
        /// The fetch thread's clients, the same `Hands` as `Fetcher`'s: each
        /// client is the binding it was made for.
        hands: Hands<u64>,
        /// Binds made so far: the latest is the machine's binding.
        binds: u64,
        in_flight: Vec<Request>,
        asker: Option<Instant>,
        pending: Option<Pending>,
        issued: u64,
        wants: u64,
        wanted: u64,
        handed: u64,
        /// Replies whose generation ended between their ask and hand-out.
        refused_stale: u64,
        /// Requests that came back after their generation ended.
        stale_replies: u64,
        /// Resumes that found no client and acted once one came back.
        waited_resumes: u64,
        /// A job that acts on a resume, picked and not yet acted on.
        picked: Option<Job<Bind, u64>>,
        /// Resumes picked with a bind or another resume landing before
        /// they were acted on.
        overtaken_resumes: u64,
        /// Initial-bind ticket requests, before any resume invalidates the seed.
        initial_prefetches: u64,
        seeded_binds: u64,
        invalidated_seeds: u64,
        local_binds: u64,
        trace: Vec<String>,
    }

    impl Model {
        fn new() -> Model {
            Model {
                core: Core::default(),
                now_ms: START_MS,
                hands: Hands::default(),
                binds: 0,
                in_flight: Vec::new(),
                asker: None,
                pending: None,
                issued: 0,
                wants: 0,
                wanted: 0,
                handed: 0,
                refused_stale: 0,
                stale_replies: 0,
                waited_resumes: 0,
                picked: None,
                overtaken_resumes: 0,
                initial_prefetches: 0,
                seeded_binds: 0,
                invalidated_seeds: 0,
                local_binds: 0,
                trace: Vec::new(),
            }
        }

        fn fail(&self, seed: u64, invariant: &str) -> ! {
            let tail = self.trace.iter().rev().take(14).rev().cloned().collect::<Vec<_>>();
            panic!("seed {seed}: {invariant}\nlast steps:\n  {}", tail.join("\n  "));
        }

        fn ask(&mut self, seed: u64, started: Instant) {
            let wanted_before = self.core.want;
            match self.core.ask(self.now_ms, started) {
                Asked::Reply { reply, kept, generation } => {
                    self.asker = None;
                    if reply["ok"] == true {
                        self.pending = Some(Pending { reply, kept, generation, started });
                    }
                }
                Asked::Wait { .. } => self.asker = Some(started),
                Asked::Stopping => self.fail(seed, "an ask saw a stop no one made"),
            }
            if !wanted_before && self.core.want {
                self.wants += 1;
            }
        }

        fn hand_out(&mut self, seed: u64) {
            let Some(pending) = self.pending.take() else { return };
            if !self.core.may_hand_out(pending.generation) {
                self.refused_stale += 1;
                // The real asker asks again within its wait.
                return self.ask(seed, pending.started);
            }
            let ticket = pending.reply["ticket"].as_str().unwrap_or_default().to_owned();
            let mut parts = ticket.split('-');
            let mut field = |prefix: char| {
                parts
                    .next()
                    .and_then(|p| p.strip_prefix(prefix))
                    .and_then(|n| n.parse::<u64>().ok())
                    .unwrap_or(u64::MAX)
            };
            let (origin, binding) = (field('g'), field('b'));
            if binding != self.binds {
                self.fail(
                    seed,
                    &format!(
                        "a ticket asked for on an older binding's client was handed out: {ticket} under binding {}",
                        self.binds
                    ),
                );
            }
            if origin != self.core.generation {
                self.fail(
                    seed,
                    &format!(
                        "a ticket from an older generation was handed out: {ticket} in generation {}",
                        self.core.generation
                    ),
                );
            }
            self.handed += 1;
        }

        fn leave(&mut self) {
            let Some(pending) = self.pending.take() else { return };
            if pending.kept
                && let Some(warm) = Warm::handout(&pending.reply, self.now_ms)
            {
                self.core.keep_unsent(warm, pending.generation);
            }
        }

        /// `Fetcher::start`: a request on the free client, leaving a spare
        /// behind when the transport makes one (only sometimes here).
        fn start(&mut self, seed: u64, rng: &mut Rng, task: Task, generation: u64) {
            let Some(binding) = self.hands.take(|b| (rng.below(2) == 0).then_some(*b)) else {
                return;
            };
            self.core.starting(generation);
            if generation == self.core.generation
                && self.in_flight.iter().any(|r| r.generation == self.core.generation)
            {
                self.fail(seed, "two requests of one generation on their way");
            }
            if task.mint && task.ticket.is_some() && generation == self.core.bound_at {
                self.initial_prefetches += 1;
            }
            self.in_flight.push(Request { generation, binding, task });
        }

        /// `Fetcher::resume`.
        fn resume(&mut self, seed: u64, rng: &mut Rng, generation: u64) {
            if !self.core.resume_holds(generation) {
                return;
            }
            let Some(&binding) = self.hands.for_resume() else {
                return self.core.defer_resume(generation);
            };
            if binding != self.binds {
                self.fail(
                    seed,
                    &format!(
                        "a resume of generation {generation} acted on binding {binding}'s client under binding {}",
                        self.binds
                    ),
                );
            }
            if self.hands.prefetch {
                self.start(seed, rng, Task::ticket("prefetched after resume", false), generation);
            }
        }

        /// `Fetcher::done`.
        fn done(&mut self, seed: u64, rng: &mut Rng, client: u64, back: Back, generation: u64) {
            self.hands.returned(client, back);
            if !back.current {
                self.stale_replies += 1;
            }
            if back.resume {
                self.waited_resumes += 1;
                self.resume(seed, rng, generation);
            }
        }

        fn fetch_step(&mut self, seed: u64, rng: &mut Rng) {
            if let Some(job) = self.picked.take() {
                return self.act(seed, rng, job);
            }
            let job = self.core.next_job(self.hands.view(), self.now_ms);
            // The fetch thread acts on a job after the lock is released: a
            // job that acts on a resume waits a step, so a bind or another
            // resume can land in between.
            if matches!(job, Job::Resume(_) | Job::Done(_, Back { resume: true, .. }, _)) {
                self.picked = Some(job);
                return;
            }
            self.act(seed, rng, job);
        }

        fn act(&mut self, seed: u64, rng: &mut Rng, job: Job<Bind, u64>) {
            if let Job::Resume(generation) | Job::Done(_, Back { resume: true, .. }, generation) =
                &job
                && *generation != self.core.generation
            {
                self.overtaken_resumes += 1;
            }
            match job {
                Job::Bind(bind, generation, seed_valid) => {
                    let Bind { binding, prefetch, seeded } = *bind;
                    self.hands.bound(binding, prefetch);
                    // Like Fetcher: validity alone cannot stand in for seed presence.
                    let keep_seed = seeded && seed_valid && self.core.generation == generation;
                    if !prefetch {
                        self.local_binds += 1;
                    } else if keep_seed {
                        self.seeded_binds += 1;
                    } else if seeded {
                        self.invalidated_seeds += 1;
                    }
                    let ticket = (prefetch && !keep_seed).then_some(("prefetched", false));
                    self.start(seed, rng, Task { mint: true, ticket }, generation);
                }
                Job::Resume(generation) => {
                    self.hands.refreshes = 0;
                    self.resume(seed, rng, generation);
                }
                Job::Wanted(generation) => {
                    self.wanted += 1;
                    if self.wanted > self.wants {
                        self.fail(seed, "more ticket requests for asks than wants");
                    }
                    let kept = self.core.warm.as_ref().is_some_and(|w| w.usable(self.now_ms));
                    if kept || self.core.answered.is_some() {
                        self.fail(seed, "a ticket request for a want a ticket already satisfies");
                    }
                    self.start(seed, rng, Task::ticket("fetched for an ask", true), generation);
                }
                Job::Refresh(generation) => {
                    if self.hands.refreshes < MAX_REFRESHES {
                        self.hands.refreshes += 1;
                        self.start(seed, rng, Task::ticket("refreshed", false), generation);
                    }
                }
                Job::Done(done, back, generation) => {
                    self.done(seed, rng, done.client, back, generation);
                }
                Job::Wait(_) | Job::Stop => {}
            }
        }

        fn ticket(&mut self, generation: u64, binding: u64) -> Value {
            self.issued += 1;
            json!({ "ok": true, "ticket": format!("g{generation}-b{binding}-{}", self.issued), "expires_at": self.now_ms / 1000 + 300 })
        }

        fn bind(&mut self, rng: &mut Rng) {
            self.binds += 1;
            let prefetch = rng.below(2) == 0;
            let seeded = prefetch && rng.below(2) == 0;
            let warm = if seeded {
                // Bind creates the next generation; use the model clock, just as
                // replies do, so these tickets can be handed out and invalidated.
                let reply = self.ticket(self.core.generation.wrapping_add(1), self.binds);
                Some(Warm::of(&reply, self.now_ms).expect("fresh model seed"))
            } else {
                None
            };
            self.core.bind_with(Bind { binding: self.binds, prefetch, seeded }, warm);
        }

        fn reply(&mut self, rng: &mut Rng) {
            if self.in_flight.is_empty() {
                return;
            }
            let at = rng.below(self.in_flight.len() as u64) as usize;
            let Request { generation, binding, task } = self.in_flight.remove(at);
            let reply = task.ticket.map(|_| {
                if rng.below(6) == 0 {
                    json!({ "ok": false, "error": { "code": "carrier.unavailable" } })
                } else {
                    self.ticket(generation, binding)
                }
            });
            self.core.finished(Done {
                generation,
                client: binding,
                task,
                reply,
                took: Duration::ZERO,
            });
        }
    }

    #[test]
    fn random_interleavings_keep_one_request_per_want_and_no_older_ticket() {
        let (mut handed, mut refused, mut wanted, mut stale, mut waited) = (0, 0, 0, 0, 0);
        let mut overtaken = 0;
        let mut initial_prefetches = 0;
        let (mut seeded_binds, mut invalidated_seeds, mut local_binds) = (0, 0, 0);
        for seed in 0..SEEDS {
            let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
            let mut model = Model::new();
            for _ in 0..STEPS {
                let step = rng.below(12);
                model.trace.push(format!(
                    "step {step}: generation {} want {} fetching {} warm {} answered {} in flight {} picked {}",
                    model.core.generation,
                    model.core.want,
                    model.core.fetching,
                    model.core.warm.is_some(),
                    model.core.answered.is_some(),
                    model.in_flight.len(),
                    model.picked.is_some()
                ));
                match step {
                    0 if model.asker.is_none() && model.pending.is_none() => {
                        model.ask(seed, Instant::now());
                    }
                    1 => {
                        if let Some(started) = model.asker {
                            model.ask(seed, started);
                        }
                    }
                    2 => model.hand_out(seed),
                    3 if rng.below(4) == 0 => model.leave(),
                    4 => model.core.note_resume(),
                    5 if rng.below(3) == 0 => model.bind(&mut rng),
                    6..=8 => model.fetch_step(seed, &mut rng),
                    9 | 10 => model.reply(&mut rng),
                    11 => model.now_ms += rng.below(120_000),
                    _ => {}
                }
            }
            handed += model.handed;
            refused += model.refused_stale;
            wanted += model.wanted;
            stale += model.stale_replies;
            waited += model.waited_resumes;
            overtaken += model.overtaken_resumes;
            initial_prefetches += model.initial_prefetches;
            seeded_binds += model.seeded_binds;
            invalidated_seeds += model.invalidated_seeds;
            local_binds += model.local_binds;
        }
        // Every path the invariants guard was driven, many times over.
        let reached = [
            ("initial-bind prefetches", initial_prefetches),
            ("seeded binds retaining their seed", seeded_binds),
            ("seeded binds replacing an invalidated seed", invalidated_seeds),
            ("binds without a carrier", local_binds),
            ("tickets handed out", handed),
            ("replies refused at the hand-out as stale", refused),
            ("ticket requests for asks", wanted),
            ("requests answered after their generation ended", stale),
            ("resumes that waited for a client", waited),
            ("resumes a bind or another resume overtook before they were acted on", overtaken),
        ];
        for (what, count) in reached {
            println!("model coverage: {what}: {count}");
            assert!(count >= SEEDS / 10, "the model reached {what} only {count} times");
        }
    }
}
