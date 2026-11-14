//! The spare-ready event's copy (`ready: M`): one event is one copy, a repeat or a claim's copy coalesces, an
//! installed copy is reported to the platform once, and a seeded sweep interleaves events, claims, warms, two
//! clients, consent off and copies that fail midway.

use super::tests::run;
use super::*;
use base64::Engine as _;
use std::cell::{Cell, RefCell};

const MACHINE: &str = "vm_0123456789abcdefghij";
const OTHER: &str = "vm_ffffffffffffffffffff";
const TEAM: &str = "team_0123456789abcdef0123";

fn flags(request: &str) -> Flags {
    Flags::parse(&["--request".to_string(), request.to_string()]).unwrap()
}

fn stdin() -> String {
    let claims = json!({"sub": "user_a", "team": TEAM}).to_string();
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims);
    format!("tok\neyJhbGciOiJFUzI1NiJ9.{payload}.sig\n")
}

fn no_call(_: &Request, _: &str, _: &str) -> Result<Value, PlatformCallError> {
    panic!("a spare-ready copy makes no platform call")
}

fn ready_of(machine: &str) -> String {
    format!(r#"{{"account":"user_a","ready":"{machine}"}}"#)
}

fn end(kind: &str, machine: &str) -> String {
    format!(r#"{{"account":"user_a","{kind}":"{machine}"}}"#)
}

fn call(dir: &Path, request: &str, now: u64) -> Value {
    run(&flags(request), dir, now, &mut stdin().as_bytes(), &no_call).unwrap()
}

#[test]
fn one_ready_event_is_one_copy_and_a_repeat_is_none() {
    let dir = tempfile::tempdir().unwrap();
    let first = call(dir.path(), &ready_of(MACHINE), 1_000_000);
    assert_eq!(
        first,
        json!({"ok": true, "machine": MACHINE, "team": TEAM, "fresh": true,
            "copy": {"machine": MACHINE, "account": "user_a", "team": TEAM}})
    );
    assert!(copy_in_flight(dir.path(), MACHINE, 1_000_100));
    let again = call(dir.path(), &ready_of(MACHINE), 1_000_200);
    assert_eq!(again, json!({"ok": true, "machine": MACHINE, "team": TEAM, "fresh": false}));
    // Another spare is its own copy.
    assert!(call(dir.path(), &ready_of(OTHER), 1_000_300).get("copy").is_some());
}

/// The platform's snapshot lists a spare that still needs the login (`spares_needing_login`, at subscribe and after
/// each install recheck), and the App asks the same `ready` for it as for the event: a listing gives one copy, the
/// event for the same spare (before or after) gives none, and a listing repeated at every recheck gives none.
#[test]
fn a_snapshot_listing_and_an_event_for_one_spare_are_one_copy() {
    let dir = tempfile::tempdir().unwrap();
    // Listed first, then the event.
    assert!(call(dir.path(), &ready_of(MACHINE), 1_000_000).get("copy").is_some());
    assert!(call(dir.path(), &ready_of(MACHINE), 1_000_100).get("copy").is_none());
    // The event first, then the listing, then the listing again at the next recheck.
    assert!(call(dir.path(), &ready_of(OTHER), 1_000_200).get("copy").is_some());
    assert!(call(dir.path(), &ready_of(OTHER), 1_000_300).get("copy").is_none());
    assert!(call(dir.path(), &ready_of(OTHER), 1_060_300).get("copy").is_none());
}

#[test]
fn a_ready_event_after_a_claim_copies_nothing_and_a_claim_after_it_waits_on_its_copy() {
    let dir = tempfile::tempdir().unwrap();
    let claim = format!(r#"{{"account":"user_a","claimed":"{MACHINE}"}}"#);
    assert!(call(dir.path(), &claim, 1_000_000).get("copy").is_some());
    assert!(call(dir.path(), &ready_of(MACHINE), 1_000_100).get("copy").is_none());
    // The other order: the event's copy is in flight, so the claim waits on it.
    let claim_other = format!(r#"{{"account":"user_a","claimed":"{OTHER}"}}"#);
    assert!(call(dir.path(), &ready_of(OTHER), 1_000_200).get("copy").is_some());
    let claimed = call(dir.path(), &claim_other, 1_000_300);
    assert_eq!((claimed.get("copy"), claimed["in_flight"].clone()), (None, json!(true)));
}

#[test]
fn a_ready_events_copy_is_never_a_warms_answer_and_a_warm_onto_it_gives_no_second_copy() {
    let dir = tempfile::tempdir().unwrap();
    let calls = Cell::new(0_usize);
    let warm = |_: &Request, _: &str, _: &str| {
        calls.set(calls.get().saturating_add(1));
        Ok(json!({"machine": MACHINE, "warm_until": 9_000_000, "vm_kind": "owner"}))
    };
    assert!(call(dir.path(), &ready_of(MACHINE), 1_000_000).get("copy").is_some());
    let answer = run(
        &flags(r#"{"account":"user_a"}"#),
        dir.path(),
        1_000_100,
        &mut stdin().as_bytes(),
        &warm,
    )
    .unwrap();
    // The warm still asks the platform (the event's record is no warm), and copies nothing more.
    assert_eq!((calls.get(), answer["fresh"].clone(), answer.get("copy")), (1, json!(false), None));
}

#[test]
fn a_receipt_holds_off_a_ready_event_and_a_failed_copy_is_copied_again_after_its_budget() {
    let dir = tempfile::tempdir().unwrap();
    assert!(call(dir.path(), &ready_of(MACHINE), 1_000_000).get("copy").is_some());
    // Consent off, or the copy failed: it ends with no receipt.
    assert_eq!(call(dir.path(), &end("finished", MACHINE), 1_000_100)["finished"], json!(true));
    assert_eq!(
        receipt(dir.path(), "user_a", MACHINE, "claude", 1_000_200)["installed"],
        json!(false)
    );
    // A repeat event within the copy's budget copies nothing; after it, one copy again.
    assert!(call(dir.path(), &ready_of(MACHINE), 1_000_200).get("copy").is_none());
    let later = 1_000_000 + COPY_BUDGET_MS;
    assert!(call(dir.path(), &ready_of(MACHINE), later).get("copy").is_some());
    assert!(call(dir.path(), &ready_of(MACHINE), later + 1).get("copy").is_none());
    // Installed: a receipt, and no event copies while it holds, even past the record's life.
    call(dir.path(), &end("installed", MACHINE), later + 2);
    let past = later + 2 + COPY_BUDGET_MS + 1;
    assert!(call(dir.path(), &ready_of(MACHINE), past).get("copy").is_none());
    assert!(call(dir.path(), &ready_of(MACHINE), later + 2 + RECEIPT_MS).get("copy").is_some());
}

#[test]
fn an_abandoned_ready_copy_is_copied_again_at_the_next_event() {
    let dir = tempfile::tempdir().unwrap();
    assert!(call(dir.path(), &ready_of(MACHINE), 1_000_000).get("copy").is_some());
    assert_eq!(call(dir.path(), &end("abandoned", MACHINE), 1_000_100)["abandoned"], json!(true));
    assert!(call(dir.path(), &ready_of(MACHINE), 1_000_200).get("copy").is_some());
}

#[test]
fn a_ready_event_is_checked_and_needs_the_team() {
    let dir = tempfile::tempdir().unwrap();
    for bad in ["vm_short", "not-a-machine", "", "vm_0123456789ABCDEFGHIJ"] {
        assert_eq!(call(dir.path(), &ready_of(bad), 1)["error_code"], json!("bad_request"));
    }
    let answer =
        run(&flags(&ready_of(MACHINE)), dir.path(), 1, &mut "tok\n".as_bytes(), &no_call).unwrap();
    assert_eq!(answer["error_code"], json!(TEAM_UNRESOLVED));
}

#[test]
fn an_installed_copy_is_reported_to_the_platform_once_and_nothing_else_is() {
    let dir = tempfile::tempdir().unwrap();
    let reports = RefCell::new(Vec::<(String, String, String)>::new());
    let report = |_: &Request, credential: &str, team: &str, machine: &str| {
        reports.borrow_mut().push((credential.to_string(), team.to_string(), machine.to_string()));
    };
    let ask = |request: &str, now| {
        run_reporting(&flags(request), dir.path(), now, &mut stdin().as_bytes(), &no_call, &report)
            .unwrap()
    };
    ask(&ready_of(MACHINE), 1_000_000);
    ask(&end("finished", MACHINE), 1_000_100);
    ask(&end("abandoned", MACHINE), 1_000_200);
    assert!(reports.borrow().is_empty());
    let later = 1_000_000 + COPY_BUDGET_MS;
    ask(&ready_of(MACHINE), later);
    assert_eq!(ask(&end("installed", MACHINE), later + 1)["finished"], json!(true));
    assert_eq!(ask(&end("installed", MACHINE), later + 2)["finished"], json!(false));
    assert_eq!(*reports.borrow(), vec![("tok".to_string(), TEAM.to_string(), MACHINE.to_string())]);
}

/// splitmix64: deterministic for a seed on every platform.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

/// What one sweep case saw.
#[derive(Default, Debug)]
struct Counts {
    copies: usize,
    ready_copies: usize,
    ready_coalesced: usize,
}

/// One seeded case: 60 steps over two spares and two clients of one account sharing one ledger (the lock
/// serializes their calls, so they interleave). Each client holds the copies it was handed until it ends them:
/// installed, finished (consent off, a failure) or abandoned (cut off midway), or gives up past the copy's
/// budget. Checked at every step: at most one copy onto a machine held at once; a ready event never copies while
/// a copy onto it is held or its receipt holds; at the end every copy handed out was ended and none is in flight.
fn sweep_case(seed: u64) -> Result<Counts, String> {
    let dir = tempfile::tempdir().map_err(|e| e.to_string())?;
    let mut rng = Rng(seed);
    let machines = [MACHINE, OTHER];
    let warm_machine = Cell::new(MACHINE);
    let warm = |_: &Request, _: &str, _: &str| {
        Ok(json!({"machine": warm_machine.get(), "warm_until": u64::MAX / 2, "vm_kind": "owner"}))
    };
    let mut now = 1_000_000_u64;
    // (client, machine, handed at)
    let mut held: Vec<(u64, &str, u64)> = Vec::new();
    let mut installed_at: [Option<u64>; 2] = [None, None];
    let mut counts = Counts::default();
    let ask = |request: &str, now: u64| {
        run(&flags(request), dir.path(), now, &mut stdin().as_bytes(), &warm)
            .ok_or_else(|| "no answer".to_string())
    };
    for step in 0..60 {
        held.retain(|(_, _, at)| now < at.saturating_add(COPY_BUDGET_MS));
        let which = usize::try_from(rng.below(2)).unwrap_or(0);
        let machine = machines[which];
        let client = rng.below(2);
        let receipt_holds =
            installed_at[which].is_some_and(|at| now < at.saturating_add(RECEIPT_MS));
        let busy = held.iter().any(|(_, m, _)| *m == machine);
        let answer = match rng.below(7) {
            0 | 1 => {
                let answer = ask(&ready_of(machine), now)?;
                if answer.get("copy").is_some() {
                    if busy || receipt_holds {
                        return Err(format!(
                            "step {step}: a ready event copied onto a covered {machine}"
                        ));
                    }
                    counts.ready_copies += 1;
                } else {
                    counts.ready_coalesced += 1;
                }
                answer
            }
            2 => ask(&format!(r#"{{"account":"user_a","claimed":"{machine}"}}"#), now)?,
            3 => {
                warm_machine.set(machine);
                ask(r#"{"account":"user_a"}"#, now)?
            }
            4 | 5 if !held.is_empty() => {
                let index = usize::try_from(rng.below(held.len() as u64)).unwrap_or(0);
                let (_, m, _) = held.remove(index);
                let kind = ["installed", "finished", "abandoned"]
                    [usize::try_from(rng.below(3)).unwrap_or(0)];
                if kind == "installed" {
                    installed_at[usize::from(m == OTHER)] = Some(now);
                }
                ask(&end(kind, m), now)?;
                json!({})
            }
            _ => {
                now = now.saturating_add(
                    [1_000, 60_000, COPY_BUDGET_MS + 1][usize::try_from(rng.below(3)).unwrap_or(0)],
                );
                json!({})
            }
        };
        if let Some(copy) = answer.get("copy") {
            let target = copy["machine"].as_str().unwrap_or_default();
            let target =
                machines.into_iter().find(|m| *m == target).ok_or("a copy onto no spare")?;
            if held.iter().any(|(_, m, _)| *m == target) {
                return Err(format!("step {step}: a second copy onto {target} while one is held"));
            }
            // A new attempt invalidates older proof even if the attempt later fails.
            installed_at[usize::from(target == OTHER)] = None;
            held.push((client, target, now));
            counts.copies += 1;
        }
        now = now.saturating_add(10);
    }
    for (_, m, _) in std::mem::take(&mut held) {
        ask(&end("finished", m), now)?;
    }
    for machine in machines {
        if copy_in_flight(dir.path(), machine, now) {
            return Err(format!("a copy onto {machine} is still in flight after every copy ended"));
        }
    }
    Ok(counts)
}

/// Seeds `0..SWEEP_SEEDS`; a failure names the lowest failing seed, to pin as its own test.
const SWEEP_SEEDS: u64 = 500;

#[test]
fn seeded_sweep_of_ready_events_claims_warms_two_clients_consent_off_and_failed_copies() {
    let mut total = Counts::default();
    for seed in 0..SWEEP_SEEDS {
        match sweep_case(seed) {
            Ok(counts) => {
                total.copies += counts.copies;
                total.ready_copies += counts.ready_copies;
                total.ready_coalesced += counts.ready_coalesced;
            }
            Err(failure) => panic!("seed {seed}: {failure}"),
        }
    }
    eprintln!("spare-ready sweep: {SWEEP_SEEDS} seeds, {total:?}");
    assert!(total.ready_copies > 0 && total.ready_coalesced > 0, "{total:?}");
}

/// A ready-triggered copy carries the same fenced scope as a warm. Only its accepted completion
/// may publish readiness, and the network report runs after releasing the local ledger lock.
#[test]
fn scoped_ready_reports_only_current_installed_or_verified_completions() {
    for outcome in ["installed", "verified"] {
        let dir = tempfile::tempdir().unwrap();
        let scope = ReceiptScope {
            platform: "https://staging.example".into(),
            team: TEAM.into(),
            install: "inst_a".into(),
            credential: "fp_a".into(),
        };
        let reports = Cell::new(0_usize);
        let report = |_: &Request, _: &str, _: &str, machine: &str| {
            assert_eq!(machine, MACHINE);
            let lock = std::fs::OpenOptions::new()
                .write(true)
                .open(dir.path().join("spare-warm.lock"))
                .unwrap();
            assert!(lock.try_lock().is_ok(), "network report still holds the ledger lock");
            reports.set(reports.get() + 1);
        };
        let ask = |mut request: Value, now| {
            request["account"] = json!("user_a");
            request["scope"] = json!(scope);
            request["currentScope"] = json!(scope);
            run_reporting(
                &flags(&request.to_string()),
                dir.path(),
                now,
                &mut stdin().as_bytes(),
                &no_call,
                &report,
            )
            .unwrap()
        };
        let first = ask(json!({"ready":MACHINE}), 1_000_000);
        let first_generation = first["copy"]["generation"].clone();
        ask(json!({"abandoned":MACHINE,"generation":first_generation}), 1_000_100);
        let second = ask(json!({"ready":MACHINE}), 1_000_200);
        let mut end = json!({"generation":first_generation});
        end[outcome] = json!(MACHINE);
        assert_eq!(ask(end.clone(), 1_000_300)["finished"], false);
        assert_eq!(reports.get(), 0);
        assert!(copy_in_flight(dir.path(), MACHINE, 1_000_300));
        end["generation"] = second["copy"]["generation"].clone();
        assert_eq!(ask(end.clone(), 1_000_400)["finished"], true);
        assert_eq!(reports.get(), 1);
        assert_eq!(
            receipt_scoped(dir.path(), "user_a", MACHINE, "claude", Some(&scope), 1_000_500)["installed"],
            true
        );
        assert_eq!(ask(end, 1_000_600)["finished"], false);
        assert_eq!(reports.get(), 1);
    }
}

#[test]
fn ready_does_not_replace_a_guest_writer_when_the_credential_scope_changes() {
    let dir = tempfile::tempdir().unwrap();
    let original = ReceiptScope {
        platform: "https://staging.example".into(),
        team: TEAM.into(),
        install: "inst_a".into(),
        credential: "fp_a".into(),
    };
    let changed = ReceiptScope { credential: "fp_b".into(), ..original.clone() };
    let ask = |scope: &ReceiptScope, mut request: Value, now| {
        request["account"] = json!("user_a");
        request["scope"] = json!(scope);
        request["currentScope"] = json!(scope);
        call(dir.path(), &request.to_string(), now)
    };
    let first = ask(&original, json!({"ready":MACHINE}), 1_000_000);
    assert!(ask(&changed, json!({"ready":MACHINE}), 1_000_100).get("copy").is_none());
    assert_eq!(read(dir.path()).copies.len(), 1);
    ask(&original, json!({"finished":MACHINE,"generation":first["copy"]["generation"]}), 1_000_200);
    let second = ask(&changed, json!({"ready":MACHINE}), 1_000_300);
    assert!(second.get("copy").is_some());
    assert_ne!(second["copy"]["generation"], first["copy"]["generation"]);
}
