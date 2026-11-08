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
mod tests;

/// How long a copy handed to the App may run before a start stops waiting on it.
pub(super) const COPY_BUDGET_MS: u64 = 180_000;
/// The longest a start waits on a warm's copy.
pub(super) const WAIT_COPY_MS: u64 = 80_000;

/// Whether a warm's login copy onto `machine` is in flight.
pub(super) fn copy_in_flight(_state: &Path, _machine: &str, _now_ms: u64) -> bool {
    false
}

/// `wait-copy`: waits for a warm's copy onto `machine`.
pub(super) fn wait_copy(
    _state: &Path,
    _machine: &str,
    _provider: &str,
    _now: &dyn Fn() -> u64,
    _pause: &dyn Fn(),
) -> Value {
    json!({"ok": true, "waited": false})
}
