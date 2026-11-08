//! Leo, Cloud V0 item 1: "A chat starts in a few seconds: ready spare, harness login attached in
//! advance, ...". On the person's intent the App asks here to warm their paused spare
//! (`POST /v1/cloud/spare/warm`, cmux-platform `SpareWarmRoute.ts`): the platform resumes it
//! unclaimed for ten minutes, and the App copies their harness login onto it, so the chat that
//! claims it finds "machine login cached". This file is the policy: how often a warm goes out, and
//! which answer means "copy now" (`fresh`). The carrier ticket the platform answers stays here.

use std::path::Path;

use cmux_json::JsonSet as _;
use serde_json::{Value, json};

use super::{Flags, refused, reservations, valid_account};
use crate::cli::{Platform, PlatformCallError};

/// A warm asked again within this long of the last one, for the same account and team, while
/// that warm still runs for longer than this, is answered from the record with `fresh: false`:
/// no platform call and no second login copy. Every composer keystroke and app activation can ask.
pub(super) const WARM_GAP_MS: u64 = 120_000;

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Request {
    pub(super) platform: Option<String>,
    pub(super) team: Option<String>,
    pub(super) account: String,
}

/// The last fresh warm, in the start-chat state folder (`spare-warm.json`).
#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq, Eq)]
struct Record {
    account: String,
    team: Option<String>,
    machine: String,
    warm_until: u64,
    at: u64,
}

pub(super) type Transport<'a> = &'a dyn Fn(&Request, &str) -> Result<Value, PlatformCallError>;

/// The real transport: the person's session credential, the selected team.
pub(super) fn post(request: &Request, credential: &str) -> Result<Value, PlatformCallError> {
    let unreachable = PlatformCallError::Unreachable;
    let origin =
        crate::cli::platform_origin(request.platform.as_deref(), &|name| std::env::var(name).ok())
            .map_err(unreachable)?;
    Platform::new(origin, credential.to_string(), std::time::Duration::from_secs(90))
        .map_err(|error| unreachable(error.message))?
        .with_team(request.team.clone())
        .post("/v1/cloud/spare/warm", json!({}))
}

fn valid_team(team: &str) -> bool {
    team.strip_prefix("team_").is_some_and(|hex| {
        hex.len() == 20 && hex.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    })
}

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
    if request.account.is_empty()
        || !valid_account(&request.account)
        || request.team.as_deref().is_some_and(|team| !valid_team(team))
    {
        return Some(refused("bad_request", "invalid spare warm"));
    }
    let mut credential = String::new();
    if stdin.read_line(&mut credential).is_err() || credential.trim().is_empty() {
        return Some(refused("unauthorized", "no session credential on stdin"));
    }
    let path = state.join("spare-warm.json");
    let last =
        std::fs::read(&path).ok().and_then(|bytes| serde_json::from_slice::<Record>(&bytes).ok());
    if let Some(last) = last.filter(|last| {
        last.account == request.account
            && last.team == request.team
            && now_ms < last.at.saturating_add(WARM_GAP_MS)
            && last.warm_until > now_ms.saturating_add(WARM_GAP_MS)
    }) {
        return Some(
            json!({"ok": true, "machine": last.machine, "warm_until": last.warm_until, "fresh": false}),
        );
    }
    let body = match transport(&request, credential.trim()) {
        Ok(body) => body,
        Err(error) => return Some(reservations::answer(Err(error))),
    };
    let Some(machine) = reservations::machine(&body).map(str::to_string) else {
        let reason = body.get("reason").and_then(Value::as_str).unwrap_or("none");
        return Some(json!({"ok": true, "machine": null, "fresh": false, "reason": reason}));
    };
    let warm_until = body.get("warm_until").and_then(Value::as_u64).unwrap_or(now_ms);
    let record = Record {
        account: request.account,
        team: request.team,
        machine: machine.clone(),
        warm_until,
        at: now_ms,
    };
    // A record that cannot be written only costs a second warm: the platform extends, never doubles.
    if let Ok(bytes) = serde_json::to_vec(&record) {
        let _ = std::fs::create_dir_all(state);
        let _ = std::fs::write(&path, bytes);
    }
    let mut answer =
        json!({"ok": true, "machine": machine, "warm_until": warm_until, "fresh": true});
    if let Some(kind) = body.get("vm_kind").and_then(Value::as_str) {
        answer.set("vm_kind", json!(kind));
    }
    Some(answer)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    const MACHINE: &str = "vm_0123456789abcdefghij";

    fn flags(request: &str) -> Flags {
        Flags::parse(&["--request".to_string(), request.to_string()]).unwrap()
    }

    #[test]
    fn a_warm_is_fresh_once_per_gap_and_never_carries_the_ticket() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Cell::new(0_usize);
        let transport = |request: &Request, credential: &str| {
            calls.set(calls.get().saturating_add(1));
            assert_eq!((request.account.as_str(), credential), ("user_a", "tok"));
            Ok(json!({"machine": MACHINE, "warm_until": 1_600_000, "vm_kind": "owner",
                "carrier": {"ticket": "v2.secret"}}))
        };
        let request = r#"{"account":"user_a","team":"team_0123456789abcdef0123"}"#;
        let warm = |now| {
            run(&flags(request), dir.path(), now, &mut "tok\n".as_bytes(), &transport).unwrap()
        };
        let first = warm(1_000_000);
        assert_eq!(
            first,
            json!({"ok": true, "machine": MACHINE, "warm_until": 1_600_000, "fresh": true, "vm_kind": "owner"})
        );
        assert!(!first.to_string().contains("secret"));
        // Within the gap: the record answers, no call, no second copy.
        assert_eq!(warm(1_060_000)["fresh"], json!(false));
        assert_eq!(calls.get(), 1);
        // Past the gap: the platform is asked again (it extends the same warm).
        assert_eq!(warm(1_200_000)["fresh"], json!(true));
        assert_eq!(calls.get(), 2);
    }

    #[test]
    fn no_spare_is_no_copy_and_a_refusal_keeps_its_code() {
        let dir = tempfile::tempdir().unwrap();
        let none = |_: &Request, _: &str| Ok(json!({"machine": null, "reason": "spare.none"}));
        let answer =
            run(&flags(r#"{"account":"u"}"#), dir.path(), 1, &mut "t\n".as_bytes(), &none).unwrap();
        assert_eq!(
            answer,
            json!({"ok": true, "machine": null, "fresh": false, "reason": "spare.none"})
        );
        let refused_ = |_: &Request, _: &str| {
            Err(PlatformCallError::Status { status: 403, code: "auth.forbidden" })
        };
        let answer =
            run(&flags(r#"{"account":"u"}"#), dir.path(), 1, &mut "t\n".as_bytes(), &refused_)
                .unwrap();
        assert_eq!(
            (answer["ok"].clone(), answer["error_code"].clone()),
            (json!(false), json!("auth.forbidden"))
        );
        let bad = run(
            &flags(r#"{"account":"u","team":"nope"}"#),
            dir.path(),
            1,
            &mut "t\n".as_bytes(),
            &none,
        )
        .unwrap();
        assert_eq!(bad["error_code"], json!("bad_request"));
        let unauth =
            run(&flags(r#"{"account":"u"}"#), dir.path(), 1, &mut "".as_bytes(), &none).unwrap();
        assert_eq!(unauth["error_code"], json!("unauthorized"));
    }
}
