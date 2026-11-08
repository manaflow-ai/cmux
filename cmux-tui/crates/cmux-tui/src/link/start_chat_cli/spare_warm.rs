//! Leo, Cloud V0 item 1: "A chat starts in a few seconds: ready spare, harness login attached in
//! advance, ...". On the person's intent the App asks here to warm their paused spare
//! (`POST /v1/cloud/spare/warm`, cmux-platform `SpareWarmRoute.ts`): the platform resumes it
//! unclaimed for ten minutes, and the App copies their harness login onto it, so the chat that
//! claims it finds "machine login cached". This file is the policy: how often a warm goes out, and
//! which answer means "copy now" (`fresh`). The carrier ticket the platform answers stays here.

use std::path::Path;

use cmux_cloud_config::identity;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{Flags, refused, reservations, valid_account};
use crate::cli::{Platform, PlatformCallError};

/// A warm asked again within this long of the last one, for the same account and team, while
/// that warm still runs for longer than this, is answered from the record with `fresh: false`:
/// no platform call and no second login copy. Every composer keystroke and app activation can ask.
/// A warm that found no spare, or failed, is an attempt: within the gap its answer is replayed
/// with no platform call, so a route that is down is not asked on every activation.
pub(super) const WARM_GAP_MS: u64 = 120_000;

/// The answer's code when the team cannot be read from the install token: no warm, no copy.
pub(super) const TEAM_UNRESOLVED: &str = "team_unresolved";
/// The answer's code when the throttle's lock cannot be taken: no warm, no copy.
pub(super) const THROTTLE_UNAVAILABLE: &str = "throttle_unavailable";

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Request {
    pub(super) platform: Option<String>,
    pub(super) account: String,
    /// The machine of a copy the App abandoned (the account or team switched mid-copy): its warm
    /// record no longer counts as copied, so the next warm answers the copy again.
    #[serde(default)]
    pub(super) abandoned: Option<String>,
}

/// The last fresh warm of one account and team (one per pair).
#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq, Eq)]
struct Record {
    account: String,
    team: Option<String>,
    machine: String,
    warm_until: u64,
    at: u64,
    /// The platform said the person owns the machine (`vm_kind: "owner"`): a copy target.
    #[serde(default)]
    owner: bool,
    /// The copy was handed to the App and not abandoned since.
    #[serde(default)]
    copy_given: bool,
}

/// The last warm of one account and team that warmed nothing (no spare, or a refusal), and its answer.
#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq)]
struct Attempt {
    account: String,
    team: String,
    at: u64,
    answer: Value,
}

/// `spare-warm.json` in the start-chat state folder.
#[derive(serde::Serialize, serde::Deserialize, Debug, Default)]
struct State {
    #[serde(default)]
    warms: Vec<Record>,
    #[serde(default)]
    attempts: Vec<Attempt>,
}

/// The platform call: the request, the person's session credential, the backend team it acts in.
pub(super) type Transport<'a> =
    &'a dyn Fn(&Request, &str, &str) -> Result<Value, PlatformCallError>;

/// The real transport: the person's session credential, in `team` (`x-cmux-team`).
pub(super) fn post(
    request: &Request,
    credential: &str,
    team: &str,
) -> Result<Value, PlatformCallError> {
    let unreachable = PlatformCallError::Unreachable;
    let origin =
        crate::cli::platform_origin(request.platform.as_deref(), &|name| std::env::var(name).ok())
            .map_err(unreachable)?;
    Platform::new(origin, credential.to_string(), std::time::Duration::from_secs(90))
        .map_err(|error| unreachable(error.message))?
        .with_team(Some(team.to_string()))
        .post("/v1/cloud/spare/warm", json!({}))
}

/// The one team of a warm and its copy: the install token's `team` claim, the backend team id the
/// App's reserve and machine routes send as `x-cmux-team`, so the platform warms the spare the
/// reserve then claims, in the same id kind its answer and the copy's checks use. None when the
/// token names no backend team: the warm is refused, never sent as personal.
fn install_team(install_token: &str) -> Option<String> {
    identity::claims(install_token.trim()).team.filter(|team| identity::is_team(team))
}

/// The throttle's lock (`spare-warm.lock`, an exclusive `flock`), held from the record's read to
/// its write, the platform call included: a second warm at the same moment waits, then finds the
/// first one's record and copies nothing. None when it cannot be taken: the warm is refused
/// before the platform call, so two warms can never both copy.
fn lock(state: &Path) -> Option<std::fs::File> {
    std::fs::create_dir_all(state).ok()?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(state.join("spare-warm.lock"))
        .ok()?;
    file.lock().ok()?;
    Some(file)
}

/// `cmux link start-chat warm-spare --request JSON`, stdin the session credential then the install
/// token. A fresh warm of a machine the person owns answers `copy`: the machine, the account and
/// the backend team the App's login copy must target, and nothing else may be copied.
pub(super) fn run(
    flags: &Flags,
    state: &Path,
    now_ms: u64,
    stdin: &mut dyn std::io::BufRead,
    transport: Transport<'_>,
) -> Option<Value> {
    let request: Request = match serde_json::from_str(flags.one("--request")?) {
        Ok(request) => request,
        Err(error) => return Some(refused("bad_request", error)),
    };
    if request.account.is_empty() || !valid_account(&request.account) {
        return Some(refused("bad_request", "invalid spare warm"));
    }
    let (mut credential, mut install) = (String::new(), String::new());
    if stdin.read_line(&mut credential).is_err() || credential.trim().is_empty() {
        return Some(refused("unauthorized", "no session credential on stdin"));
    }
    let Some(team) = stdin.read_line(&mut install).ok().and_then(|_| install_team(&install)) else {
        return Some(refused(TEAM_UNRESOLVED, "the install token names no team"));
    };
    let Some(_held) = lock(state) else {
        return Some(refused(
            THROTTLE_UNAVAILABLE,
            "the spare warm's throttle lock cannot be taken",
        ));
    };
    let path = state.join("spare-warm.json");
    let mut file: State = std::fs::read(&path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    // A record past its warm, or an attempt past the gap, is dropped: the file stays small.
    file.warms.retain(|record| record.warm_until > now_ms);
    file.attempts.retain(|attempt| now_ms < attempt.at.saturating_add(WARM_GAP_MS));
    let pair = |account: &str, other: Option<&str>| {
        account == request.account && other == Some(team.as_str())
    };
    if let Some(machine) = &request.abandoned {
        let mut found = false;
        for record in &mut file.warms {
            if pair(&record.account, record.team.as_deref()) && &record.machine == machine {
                (record.copy_given, found) = (false, true);
            }
        }
        write(&path, &file);
        return Some(json!({"ok": true, "abandoned": found}));
    }
    let copy =
        |machine: &str| json!({"machine": machine, "account": request.account, "team": team});
    let live = file.warms.iter_mut().find(|last| {
        pair(&last.account, last.team.as_deref())
            && now_ms < last.at.saturating_add(WARM_GAP_MS)
            && last.warm_until > now_ms.saturating_add(WARM_GAP_MS)
    });
    if let Some(last) = live {
        let mut answer = json!({"ok": true, "machine": last.machine, "warm_until": last.warm_until, "team": team, "fresh": false});
        // A copy abandoned since is answered again from the record: the machine is still warm.
        let regiven = last.owner && !last.copy_given;
        if regiven {
            answer.set("fresh", json!(true));
            answer.set("copy", copy(&last.machine));
            last.copy_given = true;
        }
        if regiven {
            write(&path, &file);
        }
        return Some(answer);
    }
    if let Some(attempt) =
        file.attempts.iter().find(|attempt| pair(&attempt.account, Some(attempt.team.as_str())))
    {
        let mut answer = attempt.answer.clone();
        answer.set("throttled", json!(true));
        return Some(answer);
    }
    let body = match transport(&request, credential.trim(), &team) {
        Ok(body) => body,
        Err(error) => {
            return Some(attempted(
                &path,
                file,
                &request.account,
                &team,
                now_ms,
                reservations::answer(Err(error)),
            ));
        }
    };
    let Some(machine) = reservations::machine(&body).map(str::to_string) else {
        let reason = body.get("reason").and_then(Value::as_str).unwrap_or("none");
        let answer = json!({"ok": true, "machine": null, "fresh": false, "reason": reason});
        return Some(attempted(&path, file, &request.account, &team, now_ms, answer));
    };
    let warm_until = body.get("warm_until").and_then(Value::as_u64).unwrap_or(now_ms);
    let vm_kind = body.get("vm_kind").and_then(Value::as_str);
    let owner = vm_kind == Some("owner");
    let mut answer = json!({"ok": true, "machine": machine, "warm_until": warm_until, "team": team, "fresh": true});
    if let Some(kind) = vm_kind {
        answer.set("vm_kind", json!(kind));
    }
    // Only the machine's owner gets a copy nobody asked for, never a team guest.
    if owner {
        answer.set("copy", copy(&machine));
    }
    file.warms.retain(|other| !pair(&other.account, other.team.as_deref()));
    file.attempts.retain(|other| !pair(&other.account, Some(other.team.as_str())));
    file.warms.push(Record {
        account: request.account,
        team: Some(team),
        machine,
        warm_until,
        at: now_ms,
        owner,
        copy_given: owner,
    });
    write(&path, &file);
    Some(answer)
}

/// Records a warm that warmed nothing, so the gap replays its answer, and returns that answer.
fn attempted(
    path: &Path,
    mut file: State,
    account: &str,
    team: &str,
    now_ms: u64,
    answer: Value,
) -> Value {
    file.attempts.retain(|other| other.account != account || other.team != team);
    file.attempts.push(Attempt {
        account: account.to_string(),
        team: team.to_string(),
        at: now_ms,
        answer: answer.clone(),
    });
    write(path, &file);
    answer
}

/// A state that cannot be written only costs a second warm: the platform extends, never doubles.
fn write(path: &Path, file: &State) {
    if let Ok(bytes) = serde_json::to_vec(file) {
        let _ = std::fs::write(path, bytes);
    }
}

#[cfg(test)]
mod tests {
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
        let claims = team.map_or_else(
            || json!({"sub": "user_a"}),
            |team| json!({"sub": "user_a", "team": team}),
        );
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
        assert_eq!(
            first["copy"],
            json!({"machine": MACHINE, "account": "user_a", "team": personal})
        );
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
        let warm = |request: &str,
                    input: &str,
                    transport: &dyn Fn(
            &Request,
            &str,
            &str,
        ) -> Result<Value, PlatformCallError>| {
            let dir = tempfile::tempdir().unwrap();
            run(&flags(request), dir.path(), 1, &mut input.as_bytes(), transport).unwrap()
        };
        let none =
            |_: &Request, _: &str, _: &str| Ok(json!({"machine": null, "reason": "spare.none"}));
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
}
