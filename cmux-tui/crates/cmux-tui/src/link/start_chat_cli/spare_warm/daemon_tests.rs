use super::*;
use crate::cli::PlatformCallError;
use base64::Engine as _;
use serde_json::json;
use std::sync::Mutex;

const MACHINE: &str = "vm_0123456789abcdefghij";
const TEAM: &str = "team_0123456789abcdef0123";

fn install_token() -> String {
    let claims = json!({"sub": "user_a", "team": TEAM}).to_string();
    format!(
        "eyJhbGciOiJFUzI1NiJ9.{}.sig",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims)
    )
}

fn params(claimed: Option<&str>) -> SpareWarmParams {
    SpareWarmParams {
        platform: "https://platform.example".into(),
        api: "https://api.example".into(),
        access_token: "tok".into(),
        install_token: install_token(),
        account: "user_a".into(),
        claimed: claimed.map(str::to_owned),
        dogfood: true,
        ..SpareWarmParams::default()
    }
}

fn owner(_: &Request, _: &str, _: &str) -> Result<Value, PlatformCallError> {
    Ok(json!({"machine": MACHINE, "warm_until": u64::MAX / 2, "vm_kind": "owner"}))
}

fn never(_: &Request, _: &str, _: &str) -> Result<Value, PlatformCallError> {
    panic!("a claim calls no platform route")
}

struct Yes;

impl CopyGuard for Yes {
    fn still(&self, _: &str) -> bool {
        true
    }
    fn consent(&self) -> Option<bool> {
        Some(true)
    }
}

fn yes() -> Arc<dyn CopyGuard> {
    Arc::new(Yes)
}

#[test]
fn a_warm_of_an_owned_spare_starts_its_copy_and_keeps_it_in_flight() {
    let dir = tempfile::tempdir().unwrap();
    let started = Mutex::new(Vec::new());
    let reply = warm(params(None), dir.path(), yes(), &owner, &|_, _, _, machine, team| {
        started.lock().unwrap().push((machine, team));
        true
    });
    assert_eq!(reply["copy"]["machine"], MACHINE, "{reply}");
    assert_eq!(*started.lock().unwrap(), vec![(MACHINE.to_owned(), TEAM.to_owned())]);
    // A start onto the machine waits on the copy the daemon now runs.
    assert!(super::super::copy_in_flight(dir.path(), MACHINE, now_ms()));
}

#[test]
fn a_claim_answers_from_the_ledger_with_no_platform_call() {
    let dir = tempfile::tempdir().unwrap();
    let reply = warm(params(Some(MACHINE)), dir.path(), yes(), &never, &|_, _, _, _, _| true);
    assert_eq!(reply["copy"]["machine"], MACHINE, "{reply}");
    assert_eq!(reply["fresh"], true);
    // The second claim of the same machine waits on the first copy instead of starting another.
    let again = warm(params(Some(MACHINE)), dir.path(), yes(), &never, &|_, _, _, _, _| {
        panic!("one copy per machine")
    });
    assert_eq!(again["fresh"], false, "{again}");
}

#[test]
fn a_copy_that_cannot_start_is_abandoned_so_no_start_waits_on_it() {
    let dir = tempfile::tempdir().unwrap();
    let reply = warm(params(Some(MACHINE)), dir.path(), yes(), &never, &|_, _, _, _, _| false);
    assert_eq!(reply["copy"]["machine"], MACHINE);
    assert!(!super::super::copy_in_flight(dir.path(), MACHINE, now_ms()));
}

#[test]
fn a_bad_account_is_refused_before_anything_runs() {
    let dir = tempfile::tempdir().unwrap();
    let params = SpareWarmParams { account: String::new(), ..params(None) };
    let reply = warm(params, dir.path(), yes(), &never, &|_, _, _, _, _| panic!("no copy"));
    assert_eq!(reply["ok"], false, "{reply}");
}
