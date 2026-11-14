use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_server::cloud_http::Response;
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::*;
use crate::carrier_entry::CarrierFile;
use crate::cloud::wire::{Bound, Env};

const MACHINE: &str = "vm_0123456789abcdefghij";
const SLOT: &str = "AAAAAAAAAAAAAAAAAAAAAA";

fn jwk(kid: &str) -> Value {
    json!({"kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid,
        "x": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"})
}

fn keyset(version: &str, kids: &[&str]) -> Value {
    let keys: Map<String, Value> = kids.iter().map(|kid| ((*kid).to_owned(), jwk(kid))).collect();
    json!({"version": version, "keys": keys})
}

fn route(slot: &str) -> CarrierRoute {
    CarrierRoute {
        relay: "relay+do://relay.cmux.dev".into(),
        machine: MACHINE.into(),
        slot: slot.into(),
    }
}

fn carrier_at(slot: &str, keyset: Value) -> String {
    let file = CarrierFile {
        route: route(slot),
        team: "team_0123456789abcdefghij".into(),
        issuer: Env::Dev.grant_issuer(),
        keyset,
    };
    format!("{}\n", file.to_json())
}

fn carrier_text(keyset: Value) -> String {
    carrier_at(SLOT, keyset)
}

/// Answers every keyset GET with the next scripted response, and counts
/// the GETs.
#[derive(Clone, Default)]
struct Keysets(Arc<Mutex<(Vec<Response>, usize)>>);

impl Keysets {
    fn answering(answers: Vec<Response>) -> Self {
        Keysets(Arc::new(Mutex::new((answers, 0))))
    }
    fn gets(&self) -> usize {
        self.0.lock().unwrap().1
    }
}

impl Http for Keysets {
    fn post(&self, _: &str, _: &Value, _: Option<&str>) -> Result<(u16, Value), String> {
        panic!("the keyset fetch posts nothing")
    }
    fn request_with_headers(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        _: &RequestDeadline,
    ) -> Result<Response, String> {
        assert!(url.ends_with(PATH), "{url}");
        assert!(body.is_none() && bearer.is_none(), "a public GET");
        let mut state = self.0.lock().unwrap();
        state.1 += 1;
        if state.0.is_empty() {
            return Err("no answer".into());
        }
        Ok(state.0.remove(0))
    }
}

fn client(http: Keysets) -> Box<CloudClient<Keysets>> {
    let bound = Bound {
        machine: MACHINE.into(),
        team: "team_0123456789abcdefghij".into(),
        host: "host_0123456789abcdefghij".into(),
        epoch: 1,
        install: "inst_0123456789abcdefghij".into(),
        user: "user_0123456789abcdefghij".into(),
        grant: "grant_0123456789abcdefghij".into(),
        env: Env::Dev,
        api_origin: Env::Dev.api_origin().to_owned(),
        keyset: Value::Null,
        bound_at: 1,
    };
    Box::new(CloudClient::new(http, bound, InstallKey::generate(&SystemRandom::new()).unwrap()))
}

fn ok(keyset: Value) -> Response {
    let bytes = serde_json::to_vec(&json!({"ok": true, "value": keyset})).unwrap();
    Response { status: 200, retry_after: None, bytes }
}

fn status(status: u16, retry_after: Option<&str>) -> Response {
    Response { status, retry_after: retry_after.map(str::to_owned), bytes: b"{}".to_vec() }
}

/// A bound keeper for `text`, its fetch at bind already due.
fn bound(http: &Keysets, text: &str, now: Instant) -> Keeper<Keysets> {
    let mut keeper = Keeper::default();
    assert!(keeper.on(Event::Bound(client(http.clone())), Some(text), now));
    keeper
}

#[test]
fn a_rotated_keyset_rewrites_carrier_json_and_the_same_one_does_not() {
    let old = keyset("0000000000000001", &["k1"]);
    let rotated = keyset("0000000000000002", &["k1", "k2"]);
    let text = carrier_text(old);
    let http = Keysets::answering(vec![ok(rotated.clone()), ok(rotated.clone())]);
    let mut keeper = bound(&http, &text, Instant::now());
    let fetched = keeper.fetch().unwrap();
    let written = swap_text(Some(&text), &fetched.route, &fetched.issuer, &fetched.keys)
        .expect("a rotation is kept");
    let kept = parse_file(Some(&written)).unwrap().unwrap();
    assert_eq!(kept.keyset, rotated);
    // The same keyset again (the file already holds it) changes nothing.
    let again = keeper.fetch().unwrap();
    assert_eq!(swap_text(Some(&written), &again.route, &again.issuer, &again.keys), None);
    assert_eq!(http.gets(), 2);
}

/// #37361 review F1: the write is a compare-and-swap against carrier.json
/// read again after the fetch. A route change or a removal during the
/// fetch drops the result.
#[test]
fn a_route_change_or_removal_during_the_fetch_drops_the_result() {
    let text = carrier_text(keyset("0000000000000001", &["k1"]));
    let http = Keysets::answering(vec![ok(keyset("0000000000000002", &["k2"]))]);
    let mut keeper = bound(&http, &text, Instant::now());
    let fetched = keeper.fetch().unwrap();
    let moved = carrier_at("BBBBBBBBBBBBBBBBBBBBBB", keyset("0000000000000001", &["k1"]));
    assert_eq!(swap_text(Some(&moved), &fetched.route, &fetched.issuer, &fetched.keys), None);
    assert_eq!(swap_text(None, &fetched.route, &fetched.issuer, &fetched.keys), None);
    assert!(swap_text(Some(&text), &fetched.route, &fetched.issuer, &fetched.keys).is_some());
}

/// #37361 review F3: a 429's Retry-After holds the schedule for that long,
/// capped at an hour; a 429 without one holds 60 s.
#[test]
fn a_429_honours_its_retry_after_capped() {
    let hold = |retry_after| match read_fetch(Ok(status(429, retry_after))) {
        Err(KeysetRefused::RateLimited { retry_after }) => retry_after,
        other => panic!("{other:?}"),
    };
    assert_eq!(hold(Some("120")), Duration::from_secs(120));
    assert_eq!(hold(Some("999999")), MAX_RETRY_AFTER);
    assert_eq!(hold(None), Duration::from_secs(60));
    assert_eq!(read_fetch(Err("down".into())), Err(KeysetRefused::Unavailable));

    let text = carrier_text(keyset("0000000000000001", &["k1"]));
    let http = Keysets::answering(vec![status(429, Some("120"))]);
    let now = Instant::now();
    let mut keeper = bound(&http, &text, now);
    assert!(keeper.fetch().is_none());
    let after = |secs| now + Duration::from_secs(secs);
    assert!(!keeper.on(Event::UnknownKid("k9".into()), Some(&text), after(90)));
    assert!(keeper.on(Event::UnknownKid("k9".into()), Some(&text), after(125)));
}

/// #37361 review F4: carrier.json going away stops the schedule: no
/// wakeup, no fetch, and the file coming back alone does not restart it;
/// the next bind does.
#[test]
fn carrier_json_going_away_stops_the_refresh_until_a_bind() {
    let text = carrier_text(keyset("0000000000000001", &["k1"]));
    let http = Keysets::answering(vec![]);
    let now = Instant::now();
    let mut keeper = bound(&http, &text, now);
    assert!(keeper.next_wakeup().is_some());
    assert!(!keeper.on(Event::Deadline, None, now));
    assert!(!keeper.is_active());
    assert_eq!(keeper.next_wakeup(), None);
    assert!(keeper.fetch().is_none());
    assert!(!keeper.on(Event::UnknownKid("k9".into()), Some(&text), now));
    assert!(keeper.on(Event::Bound(client(http.clone())), Some(&text), now));
    assert_eq!(http.gets(), 0);
}

#[test]
fn the_ask_names_one_valid_kid() {
    assert_eq!(check_ask(&json!({"kid": "k2"})), Ok("k2".to_owned()));
    for bad in [
        json!(null),
        json!({}),
        json!({"kid": ""}),
        json!({"kid": "a b"}),
        json!({"kid": "k", "x": 1}),
        json!({"kid": "k".repeat(65)}),
    ] {
        assert!(check_ask(&bad).is_err(), "{bad}");
    }
}

/// The thread fetches when the machine binds, writes carrier.json with the
/// new keyset (0600), and stops when the worker drops its handle.
#[test]
fn the_refresher_fetches_at_bind_and_stops_on_drop() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let paths = Paths::new(dir.path());
    let file = paths.at(CARRIER_FILE);
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    std::fs::write(&file, carrier_text(keyset("0000000000000001", &["k1"]))).unwrap();
    let rotated = keyset("0000000000000002", &["k2"]);
    let http = Keysets::answering(vec![ok(rotated.clone())]);
    let refresher = Refresher::spawn(paths, |_| {}).unwrap();
    refresher.bound(*client(http.clone()));
    drop(refresher);
    assert_eq!(http.gets(), 1);
    let kept: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(kept["keyset"], rotated);
    assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
}

/// A machine without carrier.json fetches nothing.
#[test]
fn no_carrier_no_fetch() {
    let dir = tempfile::tempdir().unwrap();
    let http = Keysets::answering(vec![]);
    let refresher = Refresher::spawn(Paths::new(dir.path()), |_| {}).unwrap();
    refresher.bound(*client(http.clone()));
    refresher.unknown_kid("k2".into());
    drop(refresher);
    assert_eq!(http.gets(), 0);
}
