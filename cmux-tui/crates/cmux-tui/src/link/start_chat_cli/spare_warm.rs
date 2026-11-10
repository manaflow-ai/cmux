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
/// A warm that found no spare, or failed, is an attempt: within the gap its answer is replayed
/// with no platform call, so a route that is down is not asked on every activation.
pub(super) const WARM_GAP_MS: u64 = 120_000;

/// The answer's code when the team cannot be read from the install token: no warm, no copy.
pub(super) const TEAM_UNRESOLVED: &str = "team_unresolved";
/// The answer's code when the throttle's lock cannot be taken: no warm, no copy.
pub(super) const THROTTLE_UNAVAILABLE: &str = "throttle_unavailable";
/// How long a copy handed to the App counts as in flight when the App never reports it finished
/// (it quit mid-copy): the platform call's 90 s and the copy's own budget.
pub(super) const COPY_BUDGET_MS: u64 = 180_000;
/// The longest a start waits on a warm's copy (inside the CLI verb's 95 s).
pub(super) const WAIT_COPY_MS: u64 = 80_000;
/// The provider whose login the warm copies: a start of any other never waits on it.
const COPIED_PROVIDER: &str = "claude";
/// How long a warm's installed login counts as the start's own: a start onto that machine for the
/// same account within this long passes no login of its own and checks none (Leo, 2026-11-10: "if
/// they're logged in why do we need to re-check their login after the critical path").
pub(super) const RECEIPT_MS: u64 = 30 * 60_000;

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Request {
    pub(super) platform: Option<String>,
    pub(super) account: String,
    /// The machine of a copy the App abandoned (the account or team switched mid-copy): its warm
    /// record no longer counts as copied, so the next warm answers the copy again.
    #[serde(default)]
    pub(super) abandoned: Option<String>,
    /// The machine of a copy that ended (installed, or given up for any other reason): no longer in
    /// flight, so a start onto it stops waiting.
    #[serde(default)]
    pub(super) finished: Option<String>,
    /// The machine of a copy that ended installed: finished as above, and its receipt kept
    /// ([`receipt`]) so a start onto it skips its own login check.
    #[serde(default)]
    pub(super) installed: Option<String>,
    /// A start's question instead of a warm: wait for a warm's copy onto this machine.
    #[serde(default)]
    pub(super) wait_copy: Option<WaitCopy>,
    /// A start's question instead of a warm: whether a warm installed this account's login on this
    /// machine within [`RECEIPT_MS`] ([`receipt`]). Same shape as `waitCopy`.
    #[serde(default)]
    pub(super) login_receipt: Option<WaitCopy>,
    /// The machine a reserve's or a claim's answer named for this account and team, instead of a
    /// warm: the copy onto it, unless one is in flight or was given ([`claim`]). No platform call.
    #[serde(default)]
    pub(super) claimed: Option<String>,
}

/// `{"waitCopy": {"machine": M, "provider": P}}`: what `wait-copy --machine M --provider P` asks.
#[derive(serde::Deserialize)]
pub(super) struct WaitCopy {
    pub(super) machine: String,
    pub(super) provider: String,
}

/// A warm's login copy in flight: registered before the platform call (no machine yet, so a start
/// onto any machine waits), given its machine when the answer hands the App a copy, and cleared
/// when the App reports it finished, when the warm copies nothing, or after [`COPY_BUDGET_MS`].
#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq, Eq)]
struct Copying {
    account: String,
    team: String,
    machine: Option<String>,
    at: u64,
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
    /// A reserve or a claim took this machine for a chat: a warm in the gap no longer answers it,
    /// so the next compose warms the next spare (the throttle is per machine, not per team).
    #[serde(default)]
    claimed: bool,
}

/// The last warm of one account and team that warmed nothing (no spare, or a refusal), and its answer.
#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq)]
struct Attempt {
    account: String,
    team: String,
    at: u64,
    answer: Value,
}

/// A warm's login copy the App reported installed: the receipt a start onto `machine` for
/// `account` takes instead of checking the login again.
#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq, Eq)]
struct Installed {
    account: String,
    team: String,
    machine: String,
    at: u64,
}

/// `spare-warm.json` in the start-chat state folder.
#[derive(serde::Serialize, serde::Deserialize, Debug, Default)]
struct State {
    #[serde(default)]
    warms: Vec<Record>,
    #[serde(default)]
    attempts: Vec<Attempt>,
    #[serde(default)]
    copies: Vec<Copying>,
    #[serde(default)]
    installed: Vec<Installed>,
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
    if let Some(refusal) = invalid(&request) {
        return Some(refusal);
    }
    let (mut credential, mut install) = (String::new(), String::new());
    if stdin.read_line(&mut credential).is_err() || credential.trim().is_empty() {
        return Some(refused("unauthorized", "no session credential on stdin"));
    }
    let _ = stdin.read_line(&mut install);
    Some(answer(request, credential.trim(), &install, state, now_ms, transport))
}

/// The refusal of a request that names no valid account or a claimed machine that is no Cloud id.
fn invalid(request: &Request) -> Option<Value> {
    if request.account.is_empty() || !valid_account(&request.account) {
        return Some(refused("bad_request", "invalid spare warm"));
    }
    if let Some(machine) = request.claimed.as_deref()
        && reservations::machine(&json!({"machine": machine})).is_none()
    {
        return Some(refused("bad_request", "the claimed machine is not a Cloud machine id"));
    }
    None
}

/// One warm, an end of its copy or a claim, as the CLI verb and the daemon's `cloud-spare-warm`
/// (`daemon.rs`) ask it: `credential` is the person's session, `install` the install token.
pub(super) fn answer(
    request: Request,
    credential: &str,
    install: &str,
    state: &Path,
    now_ms: u64,
    transport: Transport<'_>,
) -> Value {
    if let Some(refusal) = invalid(&request) {
        return refusal;
    }
    if credential.trim().is_empty() {
        return refused("unauthorized", "no session credential");
    }
    // The reservation's team (`install_team`, #36037): the spare warmed is the one the reserve claims.
    let Some(team) = install_team(install) else {
        return refused(TEAM_UNRESOLVED, "the install token names no team");
    };
    let Some(_held) = lock(state) else {
        return refused(THROTTLE_UNAVAILABLE, "the spare warm's throttle lock cannot be taken");
    };
    let path = state.join("spare-warm.json");
    let mut file = read(state);
    file.copies.retain(|copy| now_ms < copy.at.saturating_add(COPY_BUDGET_MS));
    file.installed.retain(|receipt| now_ms < receipt.at.saturating_add(RECEIPT_MS));
    // A record past its warm, or an attempt past the gap, is dropped: the file stays small.
    file.warms.retain(|record| record.warm_until > now_ms);
    file.attempts.retain(|attempt| now_ms < attempt.at.saturating_add(WARM_GAP_MS));
    let pair = |account: &str, other: Option<&str>| {
        account == request.account && other == Some(team.as_str())
    };
    let ends = |copy: &Copying, machine: &str| {
        pair(&copy.account, Some(copy.team.as_str())) && copy.machine.as_deref() == Some(machine)
    };
    let ended = request.abandoned.as_deref().or(request.finished.as_deref());
    if let Some(machine) = ended.or(request.installed.as_deref()) {
        let abandon = request.abandoned.is_some();
        if ended.is_none() {
            file.installed
                .retain(|receipt| receipt.account != request.account || receipt.machine != machine);
            file.installed.push(Installed {
                account: request.account.clone(),
                team: team.clone(),
                machine: machine.to_string(),
                at: now_ms,
            });
        }
        let mut found = false;
        for record in &mut file.warms {
            if pair(&record.account, record.team.as_deref()) && record.machine == machine {
                found = true;
                record.copy_given &= !abandon;
            }
        }
        let before = file.copies.len();
        file.copies.retain(|copy| !ends(copy, machine));
        found |= file.copies.len() != before;
        write(&path, &file);
        let mut answer = json!({"ok": true});
        answer.set(if abandon { "abandoned" } else { "finished" }, json!(found));
        return answer;
    }
    let copy =
        |machine: &str| json!({"machine": machine, "account": request.account, "team": team});
    if let Some(machine) = request.claimed.as_deref() {
        let answer = claim(&mut file, &request.account, &team, machine, now_ms, copy(machine));
        write(&path, &file);
        return answer;
    }
    let live = file.warms.iter_mut().find(|last| {
        pair(&last.account, last.team.as_deref())
            && !last.claimed
            && now_ms < last.at.saturating_add(WARM_GAP_MS)
            && last.warm_until > now_ms.saturating_add(WARM_GAP_MS)
    });
    if let Some(last) = live {
        let mut answer = json!({"ok": true, "machine": last.machine, "warm_until": last.warm_until, "team": team, "fresh": false});
        // A copy abandoned since is answered again from the record: the machine is still warm.
        if last.owner && !last.copy_given {
            answer.set("fresh", json!(true));
            answer.set("copy", copy(&last.machine));
            last.copy_given = true;
            let machine = Some(last.machine.clone());
            file.copies.push(Copying {
                account: request.account.clone(),
                team: team.clone(),
                machine,
                at: now_ms,
            });
            write(&path, &file);
        }
        return answer;
    }
    if let Some(attempt) =
        file.attempts.iter().find(|attempt| pair(&attempt.account, Some(attempt.team.as_str())))
    {
        let mut answer = attempt.answer.clone();
        answer.set("throttled", json!(true));
        return answer;
    }
    // Registered before the platform call: a start that asks meanwhile waits for this warm's answer.
    let pending =
        |copy: &Copying| copy.machine.is_none() && pair(&copy.account, Some(copy.team.as_str()));
    file.copies.push(Copying {
        account: request.account.clone(),
        team: team.clone(),
        machine: None,
        at: now_ms,
    });
    write(&path, &file);
    let body = transport(&request, credential.trim(), &team);
    file.copies.retain(|copy| !pending(copy));
    let body = match body {
        Ok(body) => body,
        Err(error) => {
            return attempted(
                &path,
                file,
                &request.account,
                &team,
                now_ms,
                reservations::answer(Err(error)),
            );
        }
    };
    let Some(machine) = reservations::machine(&body).map(str::to_string) else {
        let reason = body.get("reason").and_then(Value::as_str).unwrap_or("none");
        let answer = json!({"ok": true, "machine": null, "fresh": false, "reason": reason});
        return attempted(&path, file, &request.account, &team, now_ms, answer);
    };
    let warm_until = body.get("warm_until").and_then(Value::as_u64).unwrap_or(now_ms);
    let vm_kind = body.get("vm_kind").and_then(Value::as_str);
    let owner = vm_kind == Some("owner");
    let mut answer = json!({"ok": true, "machine": machine, "warm_until": warm_until, "team": team, "fresh": true});
    if let Some(kind) = vm_kind {
        answer.set("vm_kind", json!(kind));
    }
    // A reserve or a claim that already copies onto this machine keeps the one copy.
    let claimed = file.warms.iter().any(|other| {
        pair(&other.account, other.team.as_deref())
            && other.machine == machine
            && other.claimed
            && other.copy_given
    });
    // Only the machine's owner gets a copy nobody asked for, never a team guest.
    if owner && !claimed {
        answer.set("copy", copy(&machine));
        let machine = Some(machine.clone());
        file.copies.push(Copying {
            account: request.account.clone(),
            team: team.clone(),
            machine,
            at: now_ms,
        });
    }
    // One record per machine: a claimed machine's record stays (its copy is not given twice), the
    // pair's unclaimed one is replaced.
    file.warms.retain(|other| {
        !pair(&other.account, other.team.as_deref()) || (other.claimed && other.machine != machine)
    });
    file.attempts.retain(|other| !pair(&other.account, Some(other.team.as_str())));
    file.warms.push(Record {
        account: request.account,
        team: Some(team),
        machine,
        warm_until,
        at: now_ms,
        owner,
        copy_given: owner,
        claimed,
    });
    write(&path, &file);
    answer
}

/// `claimed: M` (under the lock): a reserve's or a claim's answer named M for this account and
/// team. A copy onto M in flight (the warm that won the race, or an earlier claim) or already given
/// answers no copy: the claim's install waits on that one (`wait-copy`) instead of starting
/// another. Otherwise the copy onto M is registered in flight and answered. Either way M's record
/// is marked claimed, so a warm in the gap no longer answers it.
fn claim(
    file: &mut State,
    account: &str,
    team: &str,
    machine: &str,
    now_ms: u64,
    copy: Value,
) -> Value {
    let ours = |other_account: &str, other_team: Option<&str>, other: &str| {
        other_account == account && other_team == Some(team) && other == machine
    };
    let in_flight = file.copies.iter().any(|copy| {
        copy.account == account && copy.team == team && copy.machine.as_deref() == Some(machine)
    });
    let given = file.warms.iter().any(|record| {
        ours(&record.account, record.team.as_deref(), &record.machine) && record.copy_given
    });
    let warm_until = now_ms.saturating_add(COPY_BUDGET_MS);
    if let Some(record) = file
        .warms
        .iter_mut()
        .find(|record| ours(&record.account, record.team.as_deref(), &record.machine))
    {
        record.claimed = true;
        record.copy_given = true;
        record.warm_until = record.warm_until.max(warm_until);
    } else {
        file.warms.push(Record {
            account: account.to_string(),
            team: Some(team.to_string()),
            machine: machine.to_string(),
            warm_until,
            at: now_ms,
            owner: true,
            copy_given: true,
            claimed: true,
        });
    }
    let mut answer = json!({"ok": true, "machine": machine, "team": team});
    if in_flight || given {
        answer.set("fresh", json!(false));
        answer.set("in_flight", json!(in_flight));
        return answer;
    }
    file.copies.push(Copying {
        account: account.to_string(),
        team: team.to_string(),
        machine: Some(machine.to_string()),
        at: now_ms,
    });
    answer.set("fresh", json!(true));
    answer.set("copy", copy);
    answer
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

/// `spare-warm.json` as last written; empty when missing or unreadable.
fn read(state: &Path) -> State {
    std::fs::read(state.join("spare-warm.json"))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

/// A state that cannot be written only costs a second warm: the platform extends, never doubles.
/// Written whole and renamed into place, so a start's unlocked read never sees half a file.
fn write(path: &Path, file: &State) {
    let staged = path.with_extension("json.tmp");
    if let Ok(bytes) = serde_json::to_vec(file)
        && std::fs::write(&staged, bytes).is_ok()
    {
        let _ = std::fs::rename(&staged, path);
    }
}

/// Whether a warm's login copy onto `machine` is in flight at `now_ms`: a warm still waiting on the
/// platform (its machine not known yet), or a copy of `machine` the App has not reported finished.
pub(super) fn copy_in_flight(state: &Path, machine: &str, now_ms: u64) -> bool {
    read(state).copies.iter().any(|copy| {
        now_ms < copy.at.saturating_add(COPY_BUDGET_MS)
            && copy.machine.as_deref().is_none_or(|other| other == machine)
    })
}

/// `wait-copy --machine M --provider P` (or the warm request's `waitCopy`): a start whose Rust
/// verdict races the warm's copy (`warm_copy_conflict`) waits here until no copy onto `machine` is
/// in flight, at most [`WAIT_COPY_MS`]. A provider the warm does not copy never waits.
pub(super) fn wait_copy(
    state: &Path,
    machine: &str,
    provider: &str,
    now: &dyn Fn() -> u64,
    pause: &dyn Fn(),
) -> Value {
    if provider != COPIED_PROVIDER {
        return json!({"ok": true, "waited": false});
    }
    let deadline = now().saturating_add(WAIT_COPY_MS);
    let mut waited = false;
    loop {
        let at = now();
        if !copy_in_flight(state, machine, at) {
            return json!({"ok": true, "waited": waited});
        }
        if at >= deadline {
            return json!({"ok": true, "waited": waited, "timed_out": true});
        }
        waited = true;
        pause();
    }
}

/// `loginReceipt` (`{"account": A, "loginReceipt": {"machine": M, "provider": P}}`): whether a
/// warm installed `account`'s login on `machine` within [`RECEIPT_MS`] and no newer copy onto it is
/// in flight. A start answered `installed: true` passes no login of its own and checks none: the
/// person is logged in, and the warm already proved it on this machine before Send. A provider the
/// warm does not copy never has one. No lock and no platform call: one read of the ledger.
pub(super) fn receipt(
    state: &Path,
    account: &str,
    machine: &str,
    provider: &str,
    now_ms: u64,
) -> Value {
    let installed = provider == COPIED_PROVIDER
        && !account.is_empty()
        && !copy_in_flight(state, machine, now_ms)
        && read(state).installed.iter().any(|receipt| {
            receipt.account == account
                && receipt.machine == machine
                && now_ms < receipt.at.saturating_add(RECEIPT_MS)
        });
    json!({"ok": true, "installed": installed})
}

/// The wait a `warm-spare` request asks for instead of a warm (`waitCopy`), if any.
pub(super) fn wait_request(flags: &Flags) -> Option<WaitCopy> {
    serde_json::from_str::<Request>(flags.one("--request")?).ok()?.wait_copy
}

/// `warm-spare` and `wait-copy` from `cmux link start-chat`, on the wall clock (the ledger's folder
/// holds the state). A `warm-spare` request with `waitCopy` is the same wait (the App's one verb).
pub(super) fn cli(action: &str, flags: &Flags, ledger: &Path) -> Option<Value> {
    let state = ledger.parent().unwrap_or(ledger);
    let pause = || std::thread::sleep(std::time::Duration::from_millis(250));
    if action == "wait-copy" {
        let (machine, provider) = (flags.one("--machine")?, flags.one("--provider")?);
        return Some(wait_copy(state, machine, provider, &now_ms, &pause));
    }
    if let Some(wait) = wait_request(flags) {
        return Some(wait_copy(state, &wait.machine, &wait.provider, &now_ms, &pause));
    }
    if let Some(request) =
        flags.one("--request").and_then(|request| serde_json::from_str::<Request>(request).ok())
        && let Some(asked) = request.login_receipt
    {
        return Some(receipt(state, &request.account, &asked.machine, &asked.provider, now_ms()));
    }
    run(flags, state, now_ms(), &mut std::io::stdin().lock(), &post)
}

/// The one team of a send's reservation, its bind and the spare warm: the install token's `team`
/// claim, the backend team (`team_…`) the App's machine list, creates and billing send as
/// `x-cmux-team` (#36037), so the spare warmed is the one the reservation claims and the list
/// shows. None when the token names no backend team.
pub(super) fn install_team(install_token: &str) -> Option<String> {
    cmux_cloud_config::identity::claims(install_token.trim())
        .team
        .filter(|team| cmux_cloud_config::identity::is_team(team))
}

/// Milliseconds since 1970 by the wall clock.
fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| u64::try_from(since.as_millis()).unwrap_or(u64::MAX))
        .unwrap_or_default()
}

/// An install token whose `team` claim is `team` (tests of the reservation's and the warm's team).
#[cfg(test)]
pub(super) fn install_token(team: &str) -> String {
    use base64::Engine as _;
    let claims = json!({"sub": "user_a", "team": team}).to_string();
    format!(
        "eyJhbGciOiJFUzI1NiJ9.{}.sig",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(claims)
    )
}

#[cfg(test)]
mod tests;

#[cfg(unix)]
pub(super) mod daemon;
#[cfg(unix)]
mod login_copy;
#[cfg(unix)]
mod scripts;
