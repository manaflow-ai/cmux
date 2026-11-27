//! `_acpmux/place_set`, `_acpmux/place_undo` and `_acpmux/place_get`: move an existing chat from
//! the place menu (`acpmux session place-set`). The rules are `place_move.rs`'s; this gathers what
//! they read, keeps the chat's pin, writes the move line and runs the move.
//!
//! * `place_set {sessionId | sessionIds, place, confirm?, why?}`, `place` being
//!   `{"mode":"auto"}`, `{"mode":"cloud"}` or
//!   `{"mode":"machine","machine":ID,"cwd":PATH?}`. Answers `{"chats":[{sessionId, state, mode,
//!   leftBehind, reason?}]}`, one per chat (a single `sessionId` also gets its chat's fields at
//!   the top level).
//! * `place_undo {sessionId, confirm?}`: moves back to where the newest `moved` line came from.
//! * `place_get {sessionId | sessionIds}`: the pin, and where a move stands.
//!
//! The move to a machine is the existing `acpmux session move` (this daemon runs it as a child),
//! so a chat moves exactly as `session move` moves it: `--carry-changes`, the branch pushed, the
//! worktree made there. Cloud starts a fresh Cloud machine and moves the chat onto it with the
//! `cmux` CLI (`CMUX_BIN`, else `cmux` on PATH), the same two steps a hybrid start's driver runs
//! (`place_move::cloud_new_words`, `cloud_move_words`): the machine starts at once, even
//! mid-turn, and the chat moves once it is up and the chat is between turns; a fresh machine the
//! chat did not move to is paused. A chat between turns moves now; a running one waits for its
//! turn to end here and then moves (`after_turn`). The move line (transcript kind `moved`) is
//! written as the move starts, by design: it must travel with the chat, and the chat's Undo
//! reads it there. A move that fails writes one more with `failed: true` and the same `moveId`,
//! and Undo passes over that pair. The pick is stored as the chat's pin as the move starts (so
//! it travels too); a failed move puts back the pin it had. Undo moves back and restores the
//! mode the chat had before (`undo.mode` on the line), never a pin to the machine.
//!
//! A move in flight is kept on disk too (`place_pending.rs`): a daemon that dies meanwhile takes
//! it up on its next start ([`resume`]): one that was waiting for the turn goes on, one cut while
//! its machine started or while it moved says why in one line, and its fresh machine is paused.
//! The pin is the chat's own metadata (`SessionMeta::place_mode`), so it moves with the chat; a
//! chat with none reads as `place_pin::effective` says (pinned here until this machine's
//! one-time migration ran, `hub/place_migrate.rs`; Auto after it), so nothing moves unasked.
//!
//! Not here yet: Auto's later move.

use super::place_pending::{self as pending, Pending, Stage};
use crate::hub::{EventFilter, Hub};
use crate::place_mode::PlaceMode;
use crate::place_move::{self as pm, LeftBehind, State, Target};
use crate::rpc::RpcError;
use crate::store::SessionStatus;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// The longest a chat that is mid-turn is waited for.
const TURN_WAIT: Duration = Duration::from_secs(600);
/// The longest a move runs.
const MOVE_LIMIT: Duration = Duration::from_secs(1800);
/// The longest the pause of an unused fresh Cloud machine runs.
const PAUSE_LIMIT: Duration = Duration::from_secs(120);
/// How long a pick waits for a move the target turns away before answering `moving`.
const EARLY_REFUSAL: Duration = Duration::from_secs(8);
const DEFAULT_WHY: &str = "you chose it";

/// Where a chat's move stands in this daemon's memory.
#[derive(Clone, Debug)]
enum Stand {
    AfterTurn,
    Moving,
    Failed(String),
}

fn stands() -> &'static Mutex<BTreeMap<String, Stand>> {
    static STANDS: std::sync::OnceLock<Mutex<BTreeMap<String, Stand>>> = std::sync::OnceLock::new();
    STANDS.get_or_init(Default::default)
}

fn stand_of(id: &str) -> Option<Stand> {
    stands().lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
}

fn set_stand(id: &str, stand: Option<Stand>) {
    let mut all = stands().lock().unwrap_or_else(|e| e.into_inner());
    match stand {
        Some(s) => all.insert(id.to_owned(), s),
        None => all.remove(id),
    };
}

fn ids_of(params: &Value) -> Result<(Vec<String>, bool), RpcError> {
    if let Some(list) = params.get("sessionIds").and_then(Value::as_array) {
        let ids: Vec<String> = list.iter().filter_map(Value::as_str).map(str::to_owned).collect();
        if ids.is_empty() {
            return Err(RpcError::invalid_params("sessionIds is empty"));
        }
        return Ok((ids, false));
    }
    match params.get("sessionId").and_then(Value::as_str) {
        Some(id) => Ok((vec![id.to_owned()], true)),
        None => Err(RpcError::invalid_params("sessionId or sessionIds is required")),
    }
}

/// The reply: `chats`, and for a single `sessionId` its chat's fields at the top level too.
fn reply(chats: Vec<Value>, single: bool) -> Value {
    let mut out = match (single, chats.first()) {
        (true, Some(Value::Object(first))) => first.clone(),
        _ => serde_json::Map::new(),
    };
    out.insert("chats".into(), Value::Array(chats));
    Value::Object(out)
}

fn chat(
    id: &str,
    state: State,
    mode: &PlaceMode,
    left: &[LeftBehind],
    reason: Option<String>,
) -> Value {
    let mut v = json!({
        "sessionId": id,
        "state": state,
        "mode": mode,
        "leftBehind": left,
    });
    if let (Some(reason), Some(o)) = (reason, v.as_object_mut()) {
        o.insert("reason".into(), json!(reason));
    }
    v
}

fn refused(id: &str, mode: &PlaceMode, reason: impl Into<String>) -> Value {
    chat(id, State::Refused, mode, &[], Some(reason.into()))
}

pub(super) async fn set(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let (ids, single) = ids_of(params)?;
    let place = params.get("place").ok_or_else(|| RpcError::invalid_params("place is required"))?;
    let want = pm::parse(place).map_err(RpcError::invalid_params)?;
    let cwd = place.get("cwd").and_then(Value::as_str).map(str::to_owned);
    let confirm = params.get("confirm").and_then(Value::as_bool) == Some(true);
    let why = params.get("why").and_then(Value::as_str).unwrap_or(DEFAULT_WHY).to_owned();
    let mut chats = Vec::new();
    for id in &ids {
        chats.push(one(hub, id, &want, confirm, &why, cwd.clone(), None).await);
    }
    Ok(reply(chats, single))
}

pub(super) async fn get(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let (ids, single) = ids_of(params)?;
    let mut chats = Vec::new();
    for key in &ids {
        let session = match hub.resolve(key) {
            Ok(s) => s,
            Err(e) => {
                chats.push(refused(key, &PlaceMode::Auto, e.message));
                continue;
            }
        };
        let id = session.meta().id;
        let mode = hub.place_mode_of(&session);
        chats.push(match stand_of(&id) {
            Some(Stand::AfterTurn) => chat(&id, State::AfterTurn, &mode, &[], None),
            Some(Stand::Moving) => chat(&id, State::Moving, &mode, &[], None),
            Some(Stand::Failed(why)) => chat(&id, State::Pinned, &mode, &[], Some(why)),
            None => chat(&id, State::Pinned, &mode, &[], None),
        });
    }
    Ok(reply(chats, single))
}

pub(super) async fn undo(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let id = params
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let confirm = params.get("confirm").and_then(Value::as_bool) == Some(true);
    let session = match hub.resolve(id) {
        Ok(s) => s,
        Err(e) => return Ok(reply(vec![refused(id, &PlaceMode::Auto, e.message)], true)),
    };
    let sid = session.meta().id;
    let Some((back, was)) = last_move_from(hub, &sid) else {
        let here = hub.place_mode_of(&session);
        return Ok(reply(vec![refused(&sid, &here, "this chat has no move to undo")], true));
    };
    // A line from before `undo.mode` was kept: the machine it came from, as Undo did then.
    let restore = was.unwrap_or_else(|| PlaceMode::Machine { id: back.clone() });
    let want = PlaceMode::Machine { id: back };
    Ok(reply(vec![one(hub, &sid, &want, confirm, "undo", None, Some(restore)).await], true))
}

/// The chat's newest move that happened: where it came from (`undo.machine`) and the mode it had
/// before (`undo.mode`, None on a line from before it was kept). A move line whose move failed
/// (a `failed` line with its `moveId` follows it) is no move.
fn last_move_from(hub: &Hub, id: &str) -> Option<(String, Option<PlaceMode>)> {
    let filter = EventFilter::parse(Some(&json!(["transcript"]))).ok()?;
    let mut before: Option<u64> = None;
    let mut failed = std::collections::BTreeSet::new();
    // A long chat reads page by page, newest first, and stops at the first move found.
    for _ in 0..50 {
        let page = hub.events_page(id, 0, before, 500, None, true, &filter).ok()?;
        let mut lines: Vec<_> =
            page.events.iter().filter(|r| r.dir == "mux" && r.kind == "moved").collect();
        lines.sort_by_key(|r| std::cmp::Reverse(r.seq));
        for r in lines {
            let move_id = r.msg.get("moveId").and_then(Value::as_str);
            if r.msg["failed"] == json!(true) {
                failed.extend(move_id.map(str::to_owned));
                continue;
            }
            if move_id.is_some_and(|m| failed.contains(m)) {
                continue;
            }
            let back = r.msg.pointer("/undo/machine").and_then(Value::as_str)?.to_owned();
            let was = r.msg.pointer("/undo/mode").and_then(|m| PlaceMode::from_params(m).ok());
            return Some((back, was));
        }
        before = Some(page.events.iter().map(|r| r.seq).min()?);
        if !page.has_more {
            return None;
        }
    }
    None
}

async fn one(
    hub: &Arc<Hub>,
    key: &str,
    want: &PlaceMode,
    confirm: bool,
    why: &str,
    cwd: Option<String>,
    // The pin to store in place of `want` (an Undo's: the mode before the move it undoes).
    pin: Option<PlaceMode>,
) -> Value {
    let here = crate::hub::host_label();
    let session = match hub.resolve(key) {
        Ok(s) => s,
        Err(e) => return refused(key, want, e.message),
    };
    let meta = session.meta();
    let id = meta.id.clone();
    let current = hub.place_mode_of(&session);
    if meta.status == SessionStatus::Closed {
        return refused(&id, &current, "this chat is closed");
    }
    if session.moving().is_some()
        || matches!(stand_of(&id), Some(Stand::AfterTurn | Stand::Moving))
        || pending::exists(&id)
    {
        return refused(&id, &current, "this chat is already moving");
    }
    let running = matches!(meta.status, SessionStatus::Running | SessionStatus::Waiting);
    let on_cloud = crate::cloud_host::is_cloud_vm();
    let left =
        if pm::needs_left(want, here, on_cloud) { gather(&meta.cwd).await } else { Vec::new() };
    let plan = pm::plan(want, here, on_cloud, running, &left, confirm);
    let pin = pin.unwrap_or_else(|| want.clone());
    if plan.store
        && let Err(e) = hub.set_place_mode(&session, Some(pin.clone()))
    {
        return refused(&id, &current, format!("could not store the pick: {}", e.message));
    }
    let Some(to) = plan.move_to.clone() else {
        let mode = if plan.store { &pin } else { &current };
        return chat(&id, plan.state, mode, &left, plan.reason);
    };
    // On disk before anything starts: a daemon that dies from here on finds it (`resume`).
    let mut record = Pending {
        session_id: id.clone(),
        to: match &to {
            Target::NewCloud => PlaceMode::Cloud,
            Target::Machine(m) => PlaceMode::Machine { id: m.clone() },
        },
        machine: None,
        before: meta.place_mode.clone(),
        was: current.clone(),
        pin,
        why: why.to_owned(),
        cwd,
        move_id: uuid::Uuid::now_v7().to_string(),
        stage: if to == Target::NewCloud { Stage::Starting } else { Stage::Waiting },
    };
    if let Err(e) = pending::save(&record) {
        return refused(&id, &current, format!("could not keep the move: {e}"));
    }
    set_stand(
        &id,
        Some(if plan.state == State::AfterTurn { Stand::AfterTurn } else { Stand::Moving }),
    );
    let hub = hub.clone();
    let wait = plan.state == State::AfterTurn;
    let owner = hub.clone();
    let (early_tx, early_rx) = tokio::sync::oneshot::channel::<Result<(), String>>();
    owner.scope.spawn_named(
        "place-move",
        Box::pin(async move {
            let outcome = run_move(&hub, &mut record, wait).await;
            let _ = early_tx.send(outcome.clone());
            finish(&hub, &record, outcome).await;
        }),
    );
    // A move the target turns away (an older build refusing a guarded move, say) answers within
    // moments: that reason is this pick's answer. A long move stays `moving`.
    if !wait && let Ok(Ok(Err(reason))) = tokio::time::timeout(EARLY_REFUSAL, early_rx).await {
        return refused(&id, &current, reason);
    }
    chat(&id, plan.state, &current, &left, None)
}

/// Runs the move: for Cloud starts its fresh machine first (unless `p` names it already, a move
/// taken up again), waits out a running turn, stores the pin and writes the line, then moves
/// (`acpmux session move`, or for Cloud `cmux move`). Each step is saved in `p` first.
async fn run_move(hub: &Arc<Hub>, p: &mut Pending, wait: bool) -> Result<(), String> {
    let id = p.session_id.clone();
    let session = hub.resolve(&id).map_err(|e| e.message)?;
    match p.to.clone() {
        PlaceMode::Machine { id: machine } => {
            between_turns(&session, &id, wait).await?;
            begin(hub, &session, p, &machine, None)?;
            session_move(&id, &machine, p.cwd.clone()).await
        }
        _ => {
            let machine = match p.machine.clone() {
                Some(machine) => machine,
                // Started now, mid-turn too: the machine boots while the turn runs.
                None => {
                    let machine = pm::machine_of(&cmux(&pm::cloud_new_words(), MOVE_LIMIT).await?)
                        .map_err(|e| format!("its Cloud machine did not start: {e}"))?;
                    p.machine = Some(machine.clone());
                    p.stage = Stage::Waiting;
                    pending::save(p).map_err(|e| format!("could not keep the move: {e}"))?;
                    machine
                }
            };
            between_turns(&session, &id, wait).await?;
            begin(hub, &session, p, "Cloud", Some(&machine))?;
            cmux(&pm::cloud_move_words(&id, &machine), MOVE_LIMIT).await.map(|_| ())
        }
    }
}

/// The move starts: saved as moving, the pin stored (it travels with the chat), the line written.
fn begin(
    hub: &Arc<Hub>,
    session: &Arc<crate::hub::Session>,
    p: &mut Pending,
    to: &str,
    machine: Option<&str>,
) -> Result<(), String> {
    p.stage = Stage::Moving;
    pending::save(p).map_err(|e| format!("could not keep the move: {e}"))?;
    hub.set_place_mode(session, Some(p.pin.clone()))
        .map_err(|e| format!("could not store the pick: {}", e.message))?;
    move_line(hub, session, to, machine, p);
    Ok(())
}

/// A move ended: on failure the pin it had back, its fresh machine paused, one line saying why;
/// then its record dropped.
async fn finish(hub: &Arc<Hub>, p: &Pending, outcome: Result<(), String>) {
    let id = &p.session_id;
    match outcome {
        Ok(()) => set_stand(id, None),
        Err(reason) => {
            if let Some(machine) = &p.machine {
                pause(id, machine).await;
            }
            if let Ok(session) = hub.resolve(id)
                && session.meta().status != SessionStatus::Closed
                && p.stage == Stage::Moving
                && let Err(e) = hub.set_place_mode(&session, p.before.clone())
            {
                tracing::warn!(session = %id, error = %e.message, "place_set: the pin was not put back");
            }
            fail_line(hub, id, pm::label(&p.to).as_str(), &reason, &p.move_id);
            set_stand(id, Some(Stand::Failed(reason)));
        }
    }
    pending::clear(id);
}

async fn pause(id: &str, machine: &str) {
    if let Err(e) = cmux(&pm::cloud_pause_words(machine), PAUSE_LIMIT).await {
        tracing::warn!(session = %id, %machine, error = %e, "place_set: an unused Cloud machine was not paused");
    }
}

/// Takes up every move a previous daemon left (`place_pending.rs`), once this daemon's chats
/// are read: one waiting for its chat's turn goes on; one cut while its fresh machine started or
/// while it moved ends with one line saying so, its machine paused; one whose chat left already
/// is done.
pub(crate) fn resume(hub: &Arc<Hub>) {
    for p in pending::all() {
        let owner = hub.clone();
        let hub = hub.clone();
        owner
            .scope
            .spawn_named("place-move-resume", Box::pin(async move { resume_one(&hub, p).await }));
    }
}

async fn resume_one(hub: &Arc<Hub>, mut p: Pending) {
    let id = p.session_id.clone();
    let closed = match hub.resolve(&id) {
        Ok(session) => session.meta().status == SessionStatus::Closed,
        Err(_) => true,
    };
    tracing::info!(session = %id, stage = ?p.stage, closed, "place_set: a move the last daemon left");
    match p.stage {
        // It left before this machine stopped: the move happened.
        Stage::Moving if closed => {
            set_stand(&id, None);
            pending::clear(&id);
        }
        _ if closed => {
            if let Some(machine) = &p.machine {
                pause(&id, machine).await;
            }
            pending::clear(&id);
        }
        Stage::Waiting => {
            set_stand(&id, Some(Stand::AfterTurn));
            saved_peers_up(hub).await;
            let outcome = run_move(hub, &mut p, true).await;
            finish(hub, &p, outcome).await;
        }
        Stage::Starting => {
            finish(hub, &p, Err("this machine stopped while its Cloud machine started".into()))
                .await;
        }
        Stage::Moving => {
            finish(hub, &p, Err("this machine stopped during the move".into())).await;
        }
    }
}

/// Waits until the saved peers this daemon dials are registered, as the daemon's peer-start
/// gate starts them only after its first client (or 2 s). A move that ran before would find no
/// route to the Cloud machine and go to the team hub, which refuses carried changes. Bounded:
/// a peer that never registers leaves the move to fail with its own reason.
async fn saved_peers_up(hub: &Arc<Hub>) {
    const LIMIT: Duration = Duration::from_secs(15);
    let deadline = tokio::time::Instant::now() + LIMIT;
    let _ = tokio::time::timeout(Duration::from_secs(3), hub.wait_local_ready()).await;
    let wanted: Vec<String> = hub.config.read().await.peers.keys().cloned().collect();
    loop {
        let have = hub.peers();
        let up = |name: &String| {
            have.iter().any(|p| p.get("name").and_then(serde_json::Value::as_str) == Some(name))
        };
        if wanted.iter().all(up) || tokio::time::Instant::now() >= deadline {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Waits while the chat is mid-turn (a turn started while a Cloud machine booted counts too).
async fn between_turns(
    session: &crate::hub::Session,
    id: &str,
    waited: bool,
) -> Result<(), String> {
    let started = tokio::time::Instant::now();
    let mut waited = waited;
    while matches!(session.meta().status, SessionStatus::Running | SessionStatus::Waiting) {
        if started.elapsed() > TURN_WAIT {
            return Err(format!("its turn did not end within {}s", TURN_WAIT.as_secs()));
        }
        waited = true;
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    if waited {
        set_stand(id, Some(Stand::Moving));
    }
    Ok(())
}

/// The move line, written as the move starts so it travels with the chat. `machine`: a Cloud
/// move's fresh machine. `undo`: where it came from and the mode it had, for its Undo.
fn move_line(
    hub: &Arc<Hub>,
    session: &Arc<crate::hub::Session>,
    to: &str,
    machine: Option<&str>,
    p: &Pending,
) {
    let from = crate::hub::host_label();
    let why = p.why.as_str();
    let mut line = json!({"text": pm::move_line(to, why), "to": to, "from": from, "why": why,
                          "moveId": p.move_id, "undo": {"machine": from, "mode": p.was}});
    if let (Some(machine), Some(o)) = (machine, line.as_object_mut()) {
        o.insert("machine".into(), json!(machine));
    }
    hub.append(session, "mux", "moved", line);
}

/// One `cmux --json` step ([`pm::step_answer`]), bounded by `limit`.
async fn cmux(words: &[String], limit: Duration) -> Result<Value, String> {
    let bin = std::env::var_os(crate::hosted_mcp::CMUX_BIN_ENV)
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "cmux".into());
    let mut command = tokio::process::Command::new(bin);
    command.args(words).stdin(std::process::Stdio::null()).kill_on_drop(true);
    let step = words.iter().take(2).cloned().collect::<Vec<_>>().join(" ");
    let out = match tokio::time::timeout(limit, command.output()).await {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => return Err(format!("could not run cmux {step}: {e}")),
        Err(_) => return Err(format!("cmux {step} ran past {}s", limit.as_secs())),
    };
    pm::step_answer(
        out.status.success(),
        &String::from_utf8_lossy(&out.stdout),
        &String::from_utf8_lossy(&out.stderr),
    )
}

/// `acpmux session move` of the chat to `to`.
async fn session_move(id: &str, to: &str, cwd: Option<String>) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut command = tokio::process::Command::new(exe);
    command
        .args(["--json", "session", "move", id, "--machine", to, "--carry-changes"])
        .env("ACPMUX_HOME", crate::config::home())
        .env("ACPMUX_SOCKET", crate::config::socket_path())
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    if let Some(cwd) = cwd {
        command.arg("--cwd").arg(cwd);
    }
    let out = match tokio::time::timeout(MOVE_LIMIT, command.output()).await {
        Ok(Ok(out)) => out,
        Ok(Err(e)) => return Err(format!("could not run the move: {e}")),
        Err(_) => return Err(format!("the move ran past {}s", MOVE_LIMIT.as_secs())),
    };
    if out.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&out.stderr);
    Err(stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("the move failed").to_owned())
}

/// The chat says the move did not happen (it is still here).
fn fail_line(hub: &Arc<Hub>, id: &str, to: &str, reason: &str, move_id: &str) {
    let Ok(session) = hub.resolve(id) else { return };
    // The chat left: the line would land in the closed copy here.
    if session.meta().status == SessionStatus::Closed {
        return;
    }
    hub.append(
        &session,
        "mux",
        "moved",
        json!({"text": format!("Did not move to {to} · {reason}"), "to": to, "failed": true,
               "why": reason, "moveId": move_id}),
    );
}

/// What the move would leave behind, read off this machine now. Only the chat's folder is read
/// today: a localhost server or an ssh tunnel needs the processes under the chat's agent, and
/// cmux-next never scans processes (`plans/cmux-next/pty-holder.md`), so those two kinds report
/// nothing until the holder registry can say which processes a chat owns.
async fn gather(cwd: &std::path::Path) -> Vec<LeftBehind> {
    let in_repo = tokio::process::Command::new("git")
        .args(["rev-parse", "--is-inside-work-tree"])
        .current_dir(cwd)
        .stdin(std::process::Stdio::null())
        .output()
        .await
        .map(|o| o.status.success())
        // No git: nothing says it is outside a repo.
        .unwrap_or(true);
    pm::left_behind(&pm::Inputs {
        cwd,
        in_repo,
        root: None,
        procs: &[],
        listeners: &[],
        outside: &[],
    })
}
