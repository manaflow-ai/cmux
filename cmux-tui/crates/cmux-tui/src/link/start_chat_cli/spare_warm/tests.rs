use super::*;
use base64::Engine as _;
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};

const MACHINE: &str = "vm_0123456789abcdefghij";
const TEAM: &str = "team_0123456789abcdef0123";

fn flags(request: &str) -> Flags {
    Flags::parse(&["--request".to_string(), request.to_string()]).unwrap()
}

/// An install token whose `team` claim is `team` (none: no claim).
fn install(team: Option<&str>) -> String {
    let claims = team
        .map_or_else(|| json!({"sub": "user_a"}), |team| json!({"sub": "user_a", "team": team}));
    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims.to_string());
    format!("eyJhbGciOiJFUzI1NiJ9.{payload}.sig")
}

fn stdin(team: Option<&str>) -> String {
    format!("tok\n{}\n", install(team))
}

fn owner(_: &Request, _: &str, _: &str) -> Result<Value, PlatformCallError> {
    Ok(json!({"machine": MACHINE, "warm_until": 1_600_000, "vm_kind": "owner"}))
}

#[test]
fn a_team_warm_targets_its_copy_at_the_install_tokens_team() {
    let dir = tempfile::tempdir().unwrap();
    let transport = |request: &Request, credential: &str, team: &str| {
        assert_eq!((request.account.as_str(), credential, team), ("user_a", "tok", TEAM));
        Ok(json!({"machine": MACHINE, "warm_until": 1_600_000, "vm_kind": "owner",
            "carrier": {"ticket": "v2.secret"}}))
    };
    let answer = run(
        &flags(r#"{"account":"user_a"}"#),
        dir.path(),
        1_000_000,
        &mut stdin(Some(TEAM)).as_bytes(),
        &transport,
    )
    .unwrap();
    assert_eq!(
        answer,
        json!({"ok": true, "machine": MACHINE, "warm_until": 1_600_000, "team": TEAM, "fresh": true,
            "vm_kind": "owner", "copy": {"machine": MACHINE, "account": "user_a", "team": TEAM}})
    );
    assert!(!answer.to_string().contains("secret"));
}

#[test]
fn a_team_lookup_failure_refuses_the_warm_and_copies_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let calls = Cell::new(0_usize);
    let transport = |request: &Request, credential: &str, team: &str| {
        calls.set(calls.get().saturating_add(1));
        owner(request, credential, team)
    };
    // No team claim, a team that is not a backend id, no install token at all: never sent as personal.
    for input in [
        stdin(None),
        stdin(Some("8d0c3f7e-team-uuid")),
        "tok\n".to_string(),
        "tok\nnot-a-jwt\n".into(),
    ] {
        let answer = run(
            &flags(r#"{"account":"user_a"}"#),
            dir.path(),
            1,
            &mut input.as_bytes(),
            &transport,
        )
        .unwrap();
        assert_eq!(
            (answer["ok"].clone(), answer["error_code"].clone()),
            (json!(false), json!(TEAM_UNRESOLVED))
        );
        assert!(answer.get("copy").is_none() && answer.get("machine").is_none());
    }
    assert_eq!(calls.get(), 0);
}

#[test]
fn a_personal_warm_is_its_personal_team_and_a_guest_gets_no_copy() {
    let dir = tempfile::tempdir().unwrap();
    // The personal install token names the person's own backend team: the platform's personal scope.
    let personal = "team_ffffffffffffffffffff";
    let warm = |kind: &'static str, now| {
        let transport = move |_: &Request, _: &str, team: &str| {
            assert_eq!(team, personal);
            Ok(json!({"machine": MACHINE, "warm_until": 9_000_000, "vm_kind": kind}))
        };
        run(
            &flags(r#"{"account":"user_a"}"#),
            dir.path(),
            now,
            &mut stdin(Some(personal)).as_bytes(),
            &transport,
        )
        .unwrap()
    };
    let first = warm("owner", 1_000_000);
    assert_eq!(first["copy"], json!({"machine": MACHINE, "account": "user_a", "team": personal}));
    let guest = run(
        &flags(r#"{"account":"user_b"}"#),
        dir.path(),
        1_000_000,
        &mut stdin(Some(personal)).as_bytes(),
        &|_: &Request, _: &str, _: &str| {
            Ok(json!({"machine": MACHINE, "warm_until": 9_000_000, "vm_kind": "team"}))
        },
    )
    .unwrap();
    assert_eq!((guest["fresh"].clone(), guest.get("copy")), (json!(true), None));
    // Within the gap the record answers: no call, no second copy.
    let again = warm("owner", 1_060_000);
    assert_eq!((again["fresh"].clone(), again.get("copy")), (json!(false), None));
    // Past the gap the platform is asked again (it extends the same warm).
    assert_eq!(warm("owner", 1_200_000)["fresh"], json!(true));
}

#[test]
fn concurrent_warms_take_the_lock_and_only_one_is_fresh() {
    let dir = tempfile::tempdir().unwrap();
    let calls = AtomicUsize::new(0);
    let transport = |request: &Request, credential: &str, team: &str| {
        calls.fetch_add(1, Ordering::SeqCst);
        // Long enough that every other thread reaches the lock while this call runs.
        std::thread::sleep(std::time::Duration::from_millis(50));
        owner(request, credential, team)
    };
    let answers: Vec<Value> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..8)
            .map(|_| {
                scope.spawn(|| {
                    run(
                        &flags(r#"{"account":"user_a"}"#),
                        dir.path(),
                        1_000_000,
                        &mut stdin(Some(TEAM)).as_bytes(),
                        &transport,
                    )
                    .unwrap()
                })
            })
            .collect();
        handles.into_iter().map(|handle| handle.join().unwrap()).collect()
    });
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(answers.iter().filter(|answer| answer["fresh"] == json!(true)).count(), 1);
    assert_eq!(answers.iter().filter(|answer| answer.get("copy").is_some()).count(), 1);
}

#[test]
fn a_lock_that_cannot_be_taken_refuses_before_the_platform_call() {
    let dir = tempfile::tempdir().unwrap();
    // The state folder is a file: no lock file can be made there.
    let state = dir.path().join("state");
    std::fs::write(&state, b"").unwrap();
    let calls = Cell::new(0_usize);
    let transport = |request: &Request, credential: &str, team: &str| {
        calls.set(calls.get().saturating_add(1));
        owner(request, credential, team)
    };
    let answer = run(
        &flags(r#"{"account":"user_a"}"#),
        &state,
        1,
        &mut stdin(Some(TEAM)).as_bytes(),
        &transport,
    )
    .unwrap();
    assert_eq!(answer["error_code"], json!(THROTTLE_UNAVAILABLE));
    assert!(answer.get("copy").is_none());
    assert_eq!(calls.get(), 0);
}

#[test]
fn no_spare_is_no_copy_and_a_refusal_keeps_its_code() {
    let input = stdin(Some(TEAM));
    let warm =
        |request: &str,
         input: &str,
         transport: &dyn Fn(&Request, &str, &str) -> Result<Value, PlatformCallError>| {
            let dir = tempfile::tempdir().unwrap();
            run(&flags(request), dir.path(), 1, &mut input.as_bytes(), transport).unwrap()
        };
    let none = |_: &Request, _: &str, _: &str| Ok(json!({"machine": null, "reason": "spare.none"}));
    assert_eq!(
        warm(r#"{"account":"u"}"#, &input, &none),
        json!({"ok": true, "machine": null, "fresh": false, "reason": "spare.none"})
    );
    let refused_ = |_: &Request, _: &str, _: &str| {
        Err(PlatformCallError::Status { status: 403, code: "auth.forbidden", facts: None })
    };
    let answer = warm(r#"{"account":"u"}"#, &input, &refused_);
    assert_eq!(
        (answer["ok"].clone(), answer["error_code"].clone()),
        (json!(false), json!("auth.forbidden"))
    );
    assert_eq!(warm(r#"{"account":""}"#, &input, &none)["error_code"], json!("bad_request"));
    assert_eq!(warm(r#"{"account":"u"}"#, "", &none)["error_code"], json!("unauthorized"));
}

#[test]
fn no_spare_and_errors_are_attempts_the_gap_throttles() {
    for answer in [
        Ok(json!({"machine": null, "reason": "spare.none"})),
        Err(PlatformCallError::Status { status: 503, code: "owner.unreachable", facts: None }),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let calls = Cell::new(0_usize);
        let transport = |_: &Request, _: &str, _: &str| {
            calls.set(calls.get().saturating_add(1));
            answer.clone()
        };
        let warm = |now| {
            run(
                &flags(r#"{"account":"user_a"}"#),
                dir.path(),
                now,
                &mut stdin(Some(TEAM)).as_bytes(),
                &transport,
            )
            .unwrap()
        };
        let first = warm(1_000_000);
        assert!(first.get("copy").is_none());
        // Every activation within the gap replays the attempt: no platform call.
        for now in [1_010_000, 1_060_000, 1_110_000] {
            let again = warm(now);
            assert_eq!(again["throttled"], json!(true));
            assert_eq!((again["ok"].clone(), again.get("copy")), (first["ok"].clone(), None));
        }
        assert_eq!(calls.get(), 1);
        // Past the gap the platform is asked again.
        assert!(warm(1_130_000).get("throttled").is_none());
        assert_eq!(calls.get(), 2);
    }
}

#[test]
fn an_abandoned_copy_is_answered_again_within_the_gap() {
    let dir = tempfile::tempdir().unwrap();
    let calls = Cell::new(0_usize);
    let transport = |request: &Request, credential: &str, team: &str| {
        calls.set(calls.get().saturating_add(1));
        owner(request, credential, team)
    };
    let call = |request: &str, now| {
        run(&flags(request), dir.path(), now, &mut stdin(Some(TEAM)).as_bytes(), &transport)
            .unwrap()
    };
    let warm = |now| call(r#"{"account":"user_a"}"#, now);
    assert!(warm(1_000_000).get("copy").is_some());
    // The App's copy was abandoned (an account switch mid-copy).
    let abandoned = format!(r#"{{"account":"user_a","abandoned":"{MACHINE}"}}"#);
    assert_eq!(call(&abandoned, 1_010_000), json!({"ok": true, "abandoned": true}));
    // Within the gap: fresh again with its copy, from the record, with no platform call.
    let again = warm(1_020_000);
    assert_eq!(
        (again["fresh"].clone(), again["copy"]["machine"].clone()),
        (json!(true), json!(MACHINE))
    );
    assert_eq!(calls.get(), 1);
    // Handed out again: the next warm in the gap copies nothing.
    assert_eq!(warm(1_030_000)["fresh"], json!(false));
    assert!(warm(1_040_000).get("copy").is_none());
    // Another machine's abandon is not this warm's.
    let other = r#"{"account":"user_a","abandoned":"vm_ffffffffffffffffffff"}"#;
    assert_eq!(call(other, 1_050_000)["abandoned"], json!(false));
    assert_eq!(warm(1_060_000)["fresh"], json!(false));
}

#[test]
fn the_warm_and_the_reservation_resolve_the_same_team() {
    use super::super::reservations::{self, Action, Call};
    // A team account's install token names its team; a personal one names the person's own team.
    for team in [TEAM, "team_ffffffffffffffffffff"] {
        let dir = tempfile::tempdir().unwrap();
        let warmed = std::cell::RefCell::new(None::<String>);
        let warm = |request: &Request, credential: &str, used: &str| {
            *warmed.borrow_mut() = Some(used.to_string());
            owner(request, credential, used)
        };
        let answer = run(
            &flags(r#"{"account":"user_a"}"#),
            dir.path(),
            1_000_000,
            &mut stdin(Some(team)).as_bytes(),
            &warm,
        )
        .unwrap();
        let reserved = std::cell::RefCell::new(None::<Option<String>>);
        let reserve = |call: &Call, _: &str| {
            *reserved.borrow_mut() = Some(call.team.clone());
            Ok(json!({"leaseId": "lease-1", "machine": MACHINE, "expiresAt": 1}))
        };
        let compose = r#"{"composeKey":"0b6f4e2a-6d55-4c8e-9a43-1f2e3d4c5b6a"}"#;
        let reply = reservations::run_with(
            &flags(compose),
            Action::Reserve,
            &mut stdin(Some(team)).as_bytes(),
            &reserve,
        )
        .unwrap();
        assert_eq!(reply["ok"], json!(true), "{reply}");
        // One rule, one team: the spare warmed is the one the reservation claims, and the copy targets it.
        assert_eq!(warmed.borrow().as_deref(), Some(team));
        assert_eq!(*reserved.borrow(), Some(Some(team.to_string())));
        assert_eq!(answer["copy"]["team"], json!(team));
    }
    // The throttle record stays per account and team: another team's warm is its own.
    let dir = tempfile::tempdir().unwrap();
    let calls = Cell::new(0_usize);
    let transport = |request: &Request, credential: &str, team: &str| {
        calls.set(calls.get().saturating_add(1));
        owner(request, credential, team)
    };
    for team in [TEAM, "team_ffffffffffffffffffff", TEAM] {
        run(
            &flags(r#"{"account":"user_a"}"#),
            dir.path(),
            1_000_000,
            &mut stdin(Some(team)).as_bytes(),
            &transport,
        )
        .unwrap();
    }
    assert_eq!(calls.get(), 2);
}

#[test]
fn a_claude_start_during_a_pending_warm_waits_for_its_copy() {
    let dir = tempfile::tempdir().unwrap();
    let during = Cell::new(false);
    let transport = |request: &Request, credential: &str, team: &str| {
        // While the platform call runs, the machine is not known yet: a Claude start onto any machine waits.
        during.set(copy_in_flight(dir.path(), MACHINE, 1_000_000));
        owner(request, credential, team)
    };
    let call = |request: &str, now| {
        run(&flags(request), dir.path(), now, &mut stdin(Some(TEAM)).as_bytes(), &transport)
            .unwrap()
    };
    assert!(call(r#"{"account":"user_a"}"#, 1_000_000).get("copy").is_some());
    assert!(during.get());
    // The copy runs: a start onto that machine waits, one onto another machine does not.
    assert!(copy_in_flight(dir.path(), MACHINE, 1_000_500));
    assert!(!copy_in_flight(dir.path(), "vm_ffffffffffffffffffff", 1_000_500));
    assert_eq!(
        wait_copy(dir.path(), MACHINE, "codex", &|| 1_000_500, &|| panic!("codex never waits")),
        json!({"ok": true, "waited": false})
    );
    // The start waits until the App reports the copy finished.
    let finished = format!(r#"{{"account":"user_a","finished":"{MACHINE}"}}"#);
    let pauses = Cell::new(0_usize);
    let waited = wait_copy(dir.path(), MACHINE, "claude", &|| 1_000_600, &|| {
        pauses.set(pauses.get().saturating_add(1));
        assert_eq!(call(&finished, 1_000_600)["finished"], json!(true));
    });
    assert_eq!((waited, pauses.get()), (json!({"ok": true, "waited": true}), 1));
    assert!(!copy_in_flight(dir.path(), MACHINE, 1_000_700));
}

#[test]
fn a_warm_that_copies_nothing_leaves_no_copy_in_flight_and_a_stale_one_expires() {
    let dir = tempfile::tempdir().unwrap();
    let guest = |_: &Request, _: &str, _: &str| {
        Ok(json!({"machine": MACHINE, "warm_until": 9_000_000, "vm_kind": "team"}))
    };
    let answer = run(
        &flags(r#"{"account":"user_a"}"#),
        dir.path(),
        1_000_000,
        &mut stdin(Some(TEAM)).as_bytes(),
        &guest,
    )
    .unwrap();
    assert!(answer.get("copy").is_none());
    assert!(!copy_in_flight(dir.path(), MACHINE, 1_000_100));
    // An App that never reports its copy (it quit mid-copy) holds starts only until the copy's budget.
    let dir2 = tempfile::tempdir().unwrap();
    run(
        &flags(r#"{"account":"user_a"}"#),
        dir2.path(),
        1_000_000,
        &mut stdin(Some(TEAM)).as_bytes(),
        &owner,
    )
    .unwrap();
    assert!(copy_in_flight(dir2.path(), MACHINE, 1_000_100));
    assert!(!copy_in_flight(dir2.path(), MACHINE, 1_000_000 + COPY_BUDGET_MS));
    let ticks = Cell::new(1_000_100_u64);
    let waited = wait_copy(dir2.path(), MACHINE, "claude", &|| ticks.get(), &|| {
        ticks.set(ticks.get().saturating_add(10_000));
    });
    assert_eq!(waited["waited"], json!(true));
    assert!(ticks.get() <= 1_000_100 + WAIT_COPY_MS + 10_000);
}

const OTHER: &str = "vm_ffffffffffffffffffff";

/// `{"account":"user_a","claimed":M}`: a reserve or a claim answered machine M.
fn claimed(machine: &str) -> String {
    format!(r#"{{"account":"user_a","claimed":"{machine}"}}"#)
}

fn no_call(_: &Request, _: &str, _: &str) -> Result<Value, PlatformCallError> {
    panic!("a claimed machine's copy makes no platform call")
}

#[test]
fn a_claimed_machine_gets_its_own_copy_once_and_no_platform_call() {
    let dir = tempfile::tempdir().unwrap();
    let call = |request: &str, now| {
        run(&flags(request), dir.path(), now, &mut stdin(Some(TEAM)).as_bytes(), &no_call).unwrap()
    };
    let first = call(&claimed(MACHINE), 1_000_000);
    assert_eq!(
        first,
        json!({"ok": true, "machine": MACHINE, "team": TEAM, "fresh": true,
            "copy": {"machine": MACHINE, "account": "user_a", "team": TEAM}})
    );
    // The claim's install finds that copy in flight and waits on it instead of starting its own.
    assert!(copy_in_flight(dir.path(), MACHINE, 1_000_100));
    assert!(!copy_in_flight(dir.path(), OTHER, 1_000_100));
    // The reserve answered M, then the send's bind answers M again: still one copy.
    let again = call(&claimed(MACHINE), 1_000_200);
    assert_eq!((again["fresh"].clone(), again.get("copy")), (json!(false), None));
    assert_eq!(again["in_flight"], json!(true));
    let finished = format!(r#"{{"account":"user_a","finished":"{MACHINE}"}}"#);
    assert_eq!(call(&finished, 1_000_300)["finished"], json!(true));
    assert!(!copy_in_flight(dir.path(), MACHINE, 1_000_400));
    let after = call(&claimed(MACHINE), 1_000_500);
    assert_eq!((after.get("copy"), after["in_flight"].clone()), (None, json!(false)));
    // An abandoned copy (account switch) is copied again on the next claim.
    let abandoned = format!(r#"{{"account":"user_a","abandoned":"{MACHINE}"}}"#);
    assert_eq!(call(&abandoned, 1_000_600)["abandoned"], json!(true));
    assert_eq!(call(&claimed(MACHINE), 1_000_700)["copy"]["machine"], json!(MACHINE));
    // Another machine is its own copy, even within the gap.
    assert_eq!(call(&claimed(OTHER), 1_000_800)["copy"]["machine"], json!(OTHER));
}

#[test]
fn a_claimed_machine_is_checked_and_needs_the_team() {
    let dir = tempfile::tempdir().unwrap();
    let call = |request: &str, input: &str| {
        run(&flags(request), dir.path(), 1, &mut input.as_bytes(), &no_call).unwrap()
    };
    for bad in ["vm_short", "not-a-machine", "", "vm_0123456789ABCDEFGHIJ"] {
        assert_eq!(call(&claimed(bad), &stdin(Some(TEAM)))["error_code"], json!("bad_request"));
    }
    let answer = call(&claimed(MACHINE), &stdin(None));
    assert_eq!(answer["error_code"], json!(TEAM_UNRESOLVED));
    assert!(answer.get("copy").is_none());
}

#[test]
fn a_reserve_that_wins_the_race_still_gets_the_copy_and_the_warm_none_is_not_the_end() {
    // Cause 2: the reserve claimed the spare first, so the warm found none and replays that.
    let dir = tempfile::tempdir().unwrap();
    let none = |_: &Request, _: &str, _: &str| Ok(json!({"machine": null, "reason": "spare.none"}));
    let call = |request: &str, now, transport: Transport<'_>| {
        run(&flags(request), dir.path(), now, &mut stdin(Some(TEAM)).as_bytes(), transport).unwrap()
    };
    assert!(call(r#"{"account":"user_a"}"#, 1_000_000, &none).get("copy").is_none());
    // The reserve's answer names M: its copy goes out, keyed by M, with no platform call.
    let reserved = call(&claimed(MACHINE), 1_000_100, &no_call);
    assert_eq!(reserved["copy"]["machine"], json!(MACHINE));
    // The send's start onto M waits for that copy, then reads "machine login cached".
    let finished = format!(r#"{{"account":"user_a","finished":"{MACHINE}"}}"#);
    let pauses = Cell::new(0_usize);
    let waited = wait_copy(dir.path(), MACHINE, "claude", &|| 1_000_200, &|| {
        pauses.set(pauses.get().saturating_add(1));
        assert_eq!(call(&finished, 1_000_200, &no_call)["finished"], json!(true));
    });
    assert_eq!((waited, pauses.get()), (json!({"ok": true, "waited": true}), 1));
}

#[test]
fn a_warm_and_a_reserve_racing_for_one_spare_copy_it_once() {
    // Cause 2, the other order: the warm resumes M while the reserve answers M at the same moment.
    let dir = tempfile::tempdir().unwrap();
    let transport = |request: &Request, credential: &str, team: &str| {
        std::thread::sleep(std::time::Duration::from_millis(50));
        owner(request, credential, team)
    };
    let answers: Vec<Value> = std::thread::scope(|scope| {
        let warm = scope.spawn(|| {
            run(
                &flags(r#"{"account":"user_a"}"#),
                dir.path(),
                1_000_000,
                &mut stdin(Some(TEAM)).as_bytes(),
                &transport,
            )
            .unwrap()
        });
        std::thread::sleep(std::time::Duration::from_millis(10));
        let reserve = scope.spawn(|| {
            run(
                &flags(&claimed(MACHINE)),
                dir.path(),
                1_000_010,
                &mut stdin(Some(TEAM)).as_bytes(),
                &no_call,
            )
            .unwrap()
        });
        vec![warm.join().unwrap(), reserve.join().unwrap()]
    });
    let copies = answers.iter().filter(|answer| answer.get("copy").is_some()).count();
    assert_eq!(copies, 1, "{answers:?}");
    assert!(copy_in_flight(dir.path(), MACHINE, 1_000_100));
}

#[test]
fn a_second_compose_in_the_gap_warms_the_next_spare_not_the_claimed_one() {
    // Cause 4: the throttle keyed on account and team answered `fresh: false` for a spare a chat took.
    let dir = tempfile::tempdir().unwrap();
    let calls = Cell::new(0_usize);
    let transport = |_: &Request, _: &str, _: &str| {
        let machine = if calls.get() == 0 { MACHINE } else { OTHER };
        calls.set(calls.get().saturating_add(1));
        Ok(json!({"machine": machine, "warm_until": 9_000_000, "vm_kind": "owner"}))
    };
    let call = |request: &str, now| {
        run(&flags(request), dir.path(), now, &mut stdin(Some(TEAM)).as_bytes(), &transport)
            .unwrap()
    };
    let warm = |now| call(r#"{"account":"user_a"}"#, now);
    assert_eq!(warm(1_000_000)["copy"]["machine"], json!(MACHINE));
    // The first chat claims M: the warm's copy onto M is the one it gets, no second copy.
    assert!(call(&claimed(MACHINE), 1_010_000).get("copy").is_none());
    // A second compose within the gap: M is taken, so the warm asks again and copies onto the next spare.
    let second = warm(1_020_000);
    assert_eq!(
        (second["fresh"].clone(), second["copy"]["machine"].clone()),
        (json!(true), json!(OTHER))
    );
    assert_eq!(calls.get(), 2);
    // Within the gap again, the unclaimed record answers as before.
    assert_eq!(warm(1_030_000)["fresh"], json!(false));
    assert_eq!(calls.get(), 2);
}

#[test]
fn a_warm_that_answers_a_machine_a_reserve_already_copies_onto_gives_no_second_copy() {
    let dir = tempfile::tempdir().unwrap();
    let call = |request: &str, transport: Transport<'_>| {
        run(&flags(request), dir.path(), 1_000_000, &mut stdin(Some(TEAM)).as_bytes(), transport)
            .unwrap()
    };
    assert!(call(&claimed(MACHINE), &no_call).get("copy").is_some());
    let warm = call(r#"{"account":"user_a"}"#, &owner);
    assert_eq!((warm["machine"].clone(), warm.get("copy")), (json!(MACHINE), None));
}

#[test]
fn an_installed_warm_copy_is_the_starts_login_receipt() {
    let dir = tempfile::tempdir().unwrap();
    let call = |request: &str, now| {
        run(&flags(request), dir.path(), now, &mut stdin(Some(TEAM)).as_bytes(), &owner).unwrap()
    };
    let asked = |account: &str, machine: &str, provider: &str, now| {
        receipt(dir.path(), account, machine, provider, now)["installed"] == json!(true)
    };
    assert_eq!(call(r#"{"account":"user_a"}"#, 1_000_000)["copy"]["machine"], json!(MACHINE));
    // The copy is still in flight: no receipt yet, so the start checks as before (and waits on it).
    assert!(!asked("user_a", MACHINE, "claude", 1_000_100));
    // A copy that ended without installing is no receipt.
    let finished = format!(r#"{{"account":"user_a","finished":"{MACHINE}"}}"#);
    assert_eq!(call(&finished, 1_000_200)["finished"], json!(true));
    assert!(!asked("user_a", MACHINE, "claude", 1_000_300));
    // The App reports it installed: that ends the copy, and a Claude start onto it skips its login check.
    let installed = format!(r#"{{"account":"user_a","installed":"{MACHINE}"}}"#);
    assert_eq!(call(&installed, 1_000_400), json!({"ok": true, "finished": true}));
    assert!(!copy_in_flight(dir.path(), MACHINE, 1_000_500));
    assert!(asked("user_a", MACHINE, "claude", 1_000_500));
    // Only that account, that machine, the copied provider, and within the receipt's life.
    assert!(!asked("user_b", MACHINE, "claude", 1_000_500));
    assert!(!asked("user_a", "vm_ffffffffffffffffffff", "claude", 1_000_500));
    assert!(!asked("user_a", MACHINE, "codex", 1_000_500));
    assert!(!asked("", MACHINE, "claude", 1_000_500));
    assert!(asked("user_a", MACHINE, "claude", 1_000_400 + RECEIPT_MS - 1));
    assert!(!asked("user_a", MACHINE, "claude", 1_000_400 + RECEIPT_MS));
}

#[test]
fn a_newer_copy_in_flight_holds_the_receipt_until_it_ends() {
    let dir = tempfile::tempdir().unwrap();
    let call = |request: &str, now| {
        run(&flags(request), dir.path(), now, &mut stdin(Some(TEAM)).as_bytes(), &no_call).unwrap()
    };
    let installed = format!(r#"{{"account":"user_a","installed":"{MACHINE}"}}"#);
    call(&installed, 1_000_000);
    assert_eq!(
        receipt(dir.path(), "user_a", MACHINE, "claude", 1_000_100)["installed"],
        json!(true)
    );
    // An abandoned copy re-answered by a claim: in flight again, so no receipt while it runs.
    assert!(call(&claimed(MACHINE), 1_000_200).get("copy").is_some());
    assert_eq!(
        receipt(dir.path(), "user_a", MACHINE, "claude", 1_000_300)["installed"],
        json!(false)
    );
    // Reported installed again: one receipt, renewed.
    call(&installed, 1_000_400);
    assert_eq!(read(dir.path()).installed.len(), 1);
    assert_eq!(read(dir.path()).installed[0].at, 1_000_400);
    assert_eq!(
        receipt(dir.path(), "user_a", MACHINE, "claude", 1_000_500)["installed"],
        json!(true)
    );
}

#[test]
fn a_receipt_question_goes_through_the_cli_with_no_credential() {
    let dir = tempfile::tempdir().unwrap();
    let ledger = dir.path().join("ledger.json");
    let installed = format!(r#"{{"account":"user_a","installed":"{MACHINE}"}}"#);
    run(&flags(&installed), dir.path(), now_ms(), &mut stdin(Some(TEAM)).as_bytes(), &no_call)
        .unwrap();
    let ask = format!(
        r#"{{"account":"user_a","loginReceipt":{{"machine":"{MACHINE}","provider":"claude"}}}}"#
    );
    assert_eq!(
        cli("warm-spare", &flags(&ask), &ledger),
        Some(json!({"ok": true, "installed": true}))
    );
}
