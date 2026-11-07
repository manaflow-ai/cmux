use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde_json::{Value, json};

use super::*;
use crate::carrier_entry::CarrierFile;
use crate::cloud::wire::{Bound, Env};

const MACHINE: &str = "vm_0123456789abcdefghij";

fn jwk(kid: &str) -> Value {
    json!({"kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid,
        "x": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"})
}

fn keyset(version: &str, kids: &[&str]) -> Value {
    let keys: serde_json::Map<String, Value> =
        kids.iter().map(|kid| ((*kid).to_owned(), jwk(kid))).collect();
    json!({"version": version, "keys": keys})
}

fn carrier_text(keyset: Value) -> String {
    let file = CarrierFile {
        route: crate::carrier_entry::CarrierRoute {
            relay: "relay+do://relay.cmux.dev".into(),
            machine: MACHINE.into(),
            slot: "AAAAAAAAAAAAAAAAAAAAAA".into(),
        },
        team: "team_0123456789abcdefghij".into(),
        issuer: Env::Dev.grant_issuer(),
        keyset,
    };
    format!("{}\n", file.to_json())
}

/// Answers every keyset GET with the next scripted `(status, body)`, and
/// counts the GETs.
#[derive(Clone, Default)]
struct Keysets(Arc<Mutex<(Vec<(u16, Value)>, usize)>>);

impl Keysets {
    fn answering(answers: Vec<(u16, Value)>) -> Self {
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
    fn request_with_deadline(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        _: &RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        assert!(url.ends_with(PATH), "{url}");
        assert!(body.is_none() && bearer.is_none(), "a public GET");
        let mut state = self.0.lock().unwrap();
        state.1 += 1;
        if state.0.is_empty() {
            return Err("no answer".into());
        }
        let (status, value) = state.0.remove(0);
        Ok((status, serde_json::to_vec(&value).unwrap()))
    }
}

fn client(http: Keysets) -> CloudClient<Keysets> {
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
    CloudClient::new(http, bound, InstallKey::generate(&SystemRandom::new()).unwrap())
}

fn ok(keyset: Value) -> (u16, Value) {
    (200, json!({"ok": true, "value": keyset}))
}

#[test]
fn a_rotated_keyset_rewrites_carrier_json_and_the_same_one_does_not() {
    let old = keyset("0000000000000001", &["k1"]);
    let rotated = keyset("0000000000000002", &["k1", "k2"]);
    let text = carrier_text(old.clone());
    let http = Keysets::answering(vec![ok(rotated.clone()), ok(old.clone())]);
    let client = client(http.clone());
    let now = Instant::now();
    let mut schedule =
        KeysetRefresh::at_bind(held(Some(&text)).unwrap(), now, Duration::from_secs(60));
    let written = fetch(&client, &mut schedule, Some(&text), now).expect("a rotation is kept");
    let kept = crate::carrier_entry::parse_file(Some(&written)).unwrap().unwrap();
    assert_eq!(kept.keyset, rotated);
    assert_eq!(schedule.held().kids(), ["k1", "k2"]);
    // The same keyset again (the file already holds it) changes nothing.
    assert_eq!(fetch(&client, &mut schedule, Some(&written), now), None);
    assert_eq!(http.gets(), 2);
}

#[test]
fn a_refused_or_rate_limited_answer_keeps_the_file_and_a_429_holds_unknown_kids() {
    let old = keyset("0000000000000001", &["k1"]);
    let text = carrier_text(old);
    let http = Keysets::answering(vec![(500, json!({})), (429, json!({}))]);
    let client = client(http.clone());
    let now = Instant::now();
    let mut schedule =
        KeysetRefresh::at_bind(held(Some(&text)).unwrap(), now, Duration::from_secs(60));
    assert_eq!(fetch(&client, &mut schedule, Some(&text), now), None);
    assert_eq!(fetch(&client, &mut schedule, Some(&text), now), None);
    assert!(!schedule.on_unknown_kid("k9", now + Duration::from_secs(1)), "held by the 429");
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
    let refresher = Refresher::spawn(paths.clone(), |_| {}).unwrap();
    refresher.bound(client(http.clone()));
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
    refresher.bound(client(http.clone()));
    refresher.unknown_kid("k2".into());
    drop(refresher);
    assert_eq!(http.gets(), 0);
}
