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
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "past the 10 s an older session host waits"
    );
    drop(server);
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
    /// While set, the next ticket request alone is held here, up to 20 s
    /// (one on a pooled connection that died in a pause).
    ticket_gate: Mutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
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
        let gate = self.0.ticket_gate.lock().unwrap().take();
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
    *live.ticket_gate.lock().unwrap() = Some((entered, gate));
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
