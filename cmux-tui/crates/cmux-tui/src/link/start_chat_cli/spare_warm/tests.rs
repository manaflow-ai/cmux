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
        Err(PlatformCallError::Status { status: 403, code: "auth.forbidden" })
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
        Err(PlatformCallError::Status { status: 503, code: "owner.unreachable" }),
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
fn a_team_switch_warms_the_active_teams_spare_with_its_own_record() {
    let dir = tempfile::tempdir().unwrap();
    let seen = std::cell::RefCell::new(Vec::<String>::new());
    let transport = |request: &Request, credential: &str, team: &str| {
        seen.borrow_mut().push(team.to_string());
        owner(request, credential, team)
    };
    // The install token is the person's own (personal team); the active Stack team picks the warm's team.
    let warm = |active: &str, now| {
        let request =
            format!(r#"{{"account":"user_a","activeTeam":"{active}","stackProjectId":"proj"}}"#);
        run(&flags(&request), dir.path(), now, &mut stdin(Some(TEAM)).as_bytes(), &transport)
            .unwrap()
    };
    let (team_a, team_b) = (
        identity::backend_team_id("proj", "stack_a"),
        identity::backend_team_id("proj", "stack_b"),
    );
    assert_eq!(warm("stack_a", 1_000_000)["copy"]["team"], json!(team_a));
    // A switch to another team warms that team's spare: its own record, not the first team's throttle.
    assert_eq!(warm("stack_b", 1_010_000)["copy"]["team"], json!(team_b));
    assert_eq!(*seen.borrow(), vec![team_a, team_b]);
    // Each team's record throttles only that team.
    assert_eq!(warm("stack_a", 1_020_000)["fresh"], json!(false));
    assert_eq!(warm("stack_b", 1_030_000)["fresh"], json!(false));
    assert_eq!(seen.borrow().len(), 2);
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
