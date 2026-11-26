//! The Auto mode socket against a fake Cloud API: one call per connection, a
//! held wait that never delays a renewal, a resume that answers the wait at
//! once, and the limits on lines and calls in flight.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use cmux_server::cloud_http::{RawRequest, Response};
use serde_json::{Value, json};

use super::{AutoSessions, Hooks, MAX_HELD};
use crate::cloud::auto_session::{Call, Kind, MAX_LINE};
use crate::cloud::auto_session_tests::{DEV, Fake, MACHINE, State, T0, auth, client, seen_of};
use crate::cloud::carrier_server::Resumes;
use crate::cloud::client::Http;
use crate::cloud::github_minter::Stop;

const SHA: &str = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";

static LOG: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn keep_log(line: &str) {
    LOG.lock().unwrap().push(line.to_owned());
}

fn fixed_now() -> u64 {
    T0
}

/// A fake whose `assignments` route says it was reached, then waits for the
/// test to let it answer. Every other route answers at once.
#[derive(Clone)]
struct Gated {
    state: Arc<Mutex<State>>,
    entered: Arc<Mutex<Sender<()>>>,
    release: Arc<Mutex<Receiver<()>>>,
}

struct Gate {
    entered: Receiver<()>,
    release: Sender<()>,
}

fn gated() -> (Gated, Gate) {
    let (entered_tx, entered) = channel();
    let (release, release_rx) = channel();
    let fake = Gated {
        state: Arc::default(),
        entered: Arc::new(Mutex::new(entered_tx)),
        release: Arc::new(Mutex::new(release_rx)),
    };
    (fake, Gate { entered, release })
}

impl Http for Gated {
    fn post(
        &self,
        url: &str,
        _body: &Value,
        _bearer: Option<&str>,
    ) -> Result<(u16, Value), String> {
        auth(&mut self.state.lock().unwrap(), url)
    }

    fn raw(&self, request: &RawRequest<'_>) -> Result<Response, String> {
        self.state.lock().unwrap().seen.push(seen_of(request));
        let body = if request.url.contains("/assignments") {
            let _ = self.entered.lock().unwrap().send(());
            // Held until the test releases it; a dropped gate answers too.
            let _ = self.release.lock().unwrap().recv();
            json!({ "assignments": [] })
        } else {
            json!({ "session": { "id": "as_1" }, "role": "holder", "leaseMs": 45_000 })
        };
        Ok(Response { status: 200, retry_after: None, bytes: body.to_string().into_bytes() })
    }
}

fn serve<H: Http + Send + 'static>(
    dir: &tempfile::TempDir,
    resumes: &Resumes,
) -> (AutoSessions<H>, PathBuf) {
    let path = dir.path().join("auto-session.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let hooks = Hooks { now: fixed_now, log: keep_log };
    let server = AutoSessions::spawn(listener, hooks, Arc::new(Stop::default()), resumes).unwrap();
    (server, path)
}

/// Sends one line and leaves the connection open for the reply.
fn send_line(path: &Path, line: &str) -> UnixStream {
    let mut stream = UnixStream::connect(path).unwrap();
    stream.write_all(format!("{line}\n").as_bytes()).unwrap();
    stream
}

fn read_reply(stream: UnixStream) -> Value {
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap_or_else(|_| panic!("no reply line: {line:?}"))
}

fn ask(path: &Path, call: &Call) -> Value {
    read_reply(send_line(path, &call.to_line()))
}

fn lease() -> Call {
    let body = json!({ "holder": format!("vm:{MACHINE}"), "epoch": 4, "needsRun": true });
    Call::write(Kind::Lease, "as_1", body)
}

#[test]
fn the_socket_answers_one_call_a_connection_as_the_bound_machine() {
    let dir = tempfile::tempdir().unwrap();
    let resumes = Resumes::default();
    let (server, path) = serve::<Fake>(&dir, &resumes);
    assert_eq!(ask(&path, &Call::machine())["error"]["code"], "vm.unbound");
    assert_eq!(ask(&path, &lease())["error"]["code"], "vm.unbound");
    let fake = Fake::default();
    let made = fake.clone();
    server.bound(MACHINE, move || Ok(client(made.clone())));
    assert_eq!(ask(&path, &Call::machine()), json!({ "ok": true, "machine": MACHINE }));
    let answer = json!({ "session": { "id": "as_1" }, "role": "holder", "leaseMs": 45_000 });
    fake.answers(200, &answer);
    fake.answers(200, &answer);
    assert_eq!(ask(&path, &lease()), json!({ "ok": true, "status": 200, "body": answer }));
    assert_eq!(ask(&path, &lease())["ok"], true);
    {
        let st = fake.0.lock().unwrap();
        assert_eq!(st.seen.len(), 2);
        assert_eq!(st.seen[0].url, format!("{DEV}/v1/auto-sessions/as_1/lease"));
        // The second call reuses the first one's idle client, bearer and all.
        assert_eq!(st.tokens_minted, 1);
        assert_eq!(st.seen[1].bearer.as_deref(), Some("bearer-1"));
    }
    // A line that is not a call, and one for another socket.
    let not_json = read_reply(send_line(&path, "hello"));
    assert_eq!(not_json["error"]["code"], "request.invalid");
    let other = read_reply(send_line(&path, r#"{"github_token": {}}"#));
    assert_eq!(other["error"]["code"], "request.invalid");
    drop(server);
}

#[test]
fn a_chunk_fits_on_one_line_and_a_longer_line_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let resumes = Resumes::default();
    let (server, path) = serve::<Fake>(&dir, &resumes);
    let fake = Fake::default();
    let made = fake.clone();
    server.bound(MACHINE, move || Ok(client(made.clone())));
    let chunk: Vec<u8> = (0..=255u8).cycle().take(1024 * 1024).collect();
    fake.0.lock().unwrap().answers.push_back(Some((204, Vec::new())));
    fake.0.lock().unwrap().answers.push_back(Some((200, chunk.clone())));
    let put = Call::chunk_put("as_1", SHA, &format!("vm:{MACHINE}"), 4, &chunk);
    assert!(put.to_line().len() < MAX_LINE);
    assert_eq!(ask(&path, &put), json!({ "ok": true, "status": 204 }));
    assert!(fake.last().bytes.as_deref() == Some(chunk.as_slice()));
    let got = ask(&path, &Call::chunk("as_1", SHA));
    assert!(BASE64.decode(got["bytes"].as_str().unwrap()).unwrap() == chunk);
    // Past 2 MiB the line is refused, whatever it says.
    let long =
        format!(r#"{{"auto_session":{{"call":"get","session":"{}"}}}}"#, "x".repeat(MAX_LINE));
    assert_eq!(read_reply(send_line(&path, &long))["error"]["code"], "request.invalid");
    assert_eq!(fake.0.lock().unwrap().seen.len(), 2);
    drop(server);
}

#[test]
fn a_held_wait_does_not_delay_a_renewal() {
    let dir = tempfile::tempdir().unwrap();
    let resumes = Resumes::default();
    let (server, path) = serve::<Gated>(&dir, &resumes);
    let (fake, gate) = gated();
    server.bound(MACHINE, move || Ok(client(fake.clone())));
    let waiting = send_line(&path, &Call::assignments(25_000).to_line());
    gate.entered.recv_timeout(Duration::from_secs(10)).unwrap();
    // The wait is at the store. Renewals go out and come back meanwhile.
    for _ in 0..3 {
        assert_eq!(ask(&path, &lease())["ok"], true);
    }
    gate.release.send(()).unwrap();
    assert_eq!(
        read_reply(waiting),
        json!({ "ok": true, "status": 200, "body": { "assignments": [] } })
    );
    drop(server);
}

#[test]
fn a_resume_answers_a_held_wait_at_once_and_the_next_one_goes_out() {
    let dir = tempfile::tempdir().unwrap();
    let resumes = Resumes::default();
    let (server, path) = serve::<Gated>(&dir, &resumes);
    let (fake, gate) = gated();
    server.bound(MACHINE, move || Ok(client(fake.clone())));
    let waiting = send_line(&path, &Call::assignments(25_000).to_line());
    gate.entered.recv_timeout(Duration::from_secs(10)).unwrap();
    let started = Instant::now();
    resumes.note();
    let reply = read_reply(waiting);
    assert_eq!(reply["error"]["code"], "auto.resumed");
    assert!(started.elapsed() < Duration::from_secs(5), "{:?}", started.elapsed());
    // The daemon asks again; that wait reaches the store while the old request is still out.
    let again = send_line(&path, &Call::assignments(25_000).to_line());
    gate.entered.recv_timeout(Duration::from_secs(10)).unwrap();
    gate.release.send(()).unwrap();
    gate.release.send(()).unwrap();
    assert_eq!(read_reply(again)["ok"], true);
    drop(server);
}

#[test]
fn held_waits_are_bounded_and_a_stop_ends_them() {
    let dir = tempfile::tempdir().unwrap();
    let resumes = Resumes::default();
    let (server, path) = serve::<Gated>(&dir, &resumes);
    let (fake, gate) = gated();
    server.bound(MACHINE, move || Ok(client(fake.clone())));
    let line = Call::assignments(25_000).to_line();
    let mut waiting = Vec::new();
    for _ in 0..MAX_HELD {
        waiting.push(send_line(&path, &line));
        gate.entered.recv_timeout(Duration::from_secs(10)).unwrap();
    }
    assert_eq!(read_reply(send_line(&path, &line))["error"]["code"], "busy");
    // A renewal still goes through with every wait slot taken.
    assert_eq!(ask(&path, &lease())["ok"], true);
    // The worker ends: each asker gets a line, not a hang, and the requests left behind end
    // by themselves.
    drop(server);
    for stream in waiting {
        assert_eq!(read_reply(stream)["error"]["code"], "auto.resumed");
    }
    drop(gate);
}
