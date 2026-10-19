//! Close requests for frontend-rendered browser tabs
//! (`frontend-tab-close-request-v1`).
//!
//! The app that renders a frontend browser tab (cmux-browser's Chromium, the
//! record's `owner`) owns the tab's existence: a page can veto a close
//! (beforeunload), and a page or an extension can remove a tab without the
//! daemon (`window.close()`, `chrome.tabs.remove`, the tab strip). So the
//! daemon never removes such a tab on its own here. It asks the owner, and
//! deletes the tab only when the owner reports it removed:
//!
//! 1. The owner app subscribes once per connection with
//!    `frontend-browser-tab-close-subscribe {owner}` (its install id, the one
//!    it puts on `new-frontend-browser-tab {owner}`). The newest live
//!    connection for an owner wins.
//! 2. Any control client asks with `request-frontend-browser-tab-close`. With
//!    a live subscriber the daemon sends that connection a targeted
//!    `frontend-browser-tab-close-requested` event with an unguessable
//!    request id, and the tab stays. With none, nothing changes and the
//!    answer is `delegated: false` (the caller may still `close-surface`).
//! 3. The owner answers `answer-frontend-browser-tab-close {request_id,
//!    outcome}`: `closing` (the close started) or `cancelled` (the page
//!    vetoed). Only the connection that got the event may answer.
//! 4. The owner reports `report-frontend-browser-tab-removed` when the tab is
//!    gone in the app, for a request (`answered`) or on its own
//!    (`user_closed`, `page_closed`, `extension`). The daemon then closes the
//!    tab in one durable commit (closed history kept), keyed by `origin` +
//!    `mutation_id`.
//!
//! Every requester gets `frontend-browser-tab-close-settled` once:
//! `removed` (also when the tab left the store by another path, such as
//! `close-surface`), `cancelled`, `owner_gone` (the owner's connection
//! ended; the tab stays, and the owner restores it when it comes back), or
//! `timed_out`. A slow or dead browser never blocks a close: when the owner
//! does not answer by the request's `deadline_ms` (default 5 s, at most
//! 30 s), the request settles `timed_out`, the owner gets the same settled
//! event, and the owner must then close the tab without a beforeunload veto
//! and report its removal. A late answer gets `accepted: false`. Crash and
//! discard are not removals; the owner reports them through
//! `update-frontend-browser-tab`. Requests are transient: they are never
//! journaled or replayed across a daemon restart.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use super::{MessageWriter, MutationRequest, Mux, workspace_mutation};
use crate::SurfaceId;
use crate::request_origin::{HelloRole, ORIGIN_FORBIDDEN, valid_install_id};

/// Advertised in `identify`.
pub(crate) const CAPABILITY: &str = "frontend-tab-close-request-v1";

const MAX_SUBSCRIBERS: usize = 16;
const MAX_OPEN_PER_OWNER: usize = 64;
const MAX_WAITERS_PER_REQUEST: usize = 16;
/// The owner's time to answer a close request.
const DEFAULT_DEADLINE_MS: u64 = 5_000;
const MAX_DEADLINE_MS: u64 = 30_000;

/// `frontend-browser-tab-close-subscribe`.
#[derive(Deserialize)]
pub(super) struct SubscribeParams {
    owner: String,
}

/// `request-frontend-browser-tab-close`.
#[derive(Deserialize)]
pub(super) struct RequestParams {
    surface: SurfaceId,
    #[serde(default)]
    reason: Option<crate::mux::CloseReason>,
    #[serde(default = "default_deadline_ms")]
    deadline_ms: u64,
}

fn default_deadline_ms() -> u64 {
    DEFAULT_DEADLINE_MS
}

/// `answer-frontend-browser-tab-close`.
#[derive(Deserialize)]
pub(super) struct AnswerParams {
    request_id: String,
    outcome: String,
}

/// `report-frontend-browser-tab-removed`.
#[derive(Deserialize)]
pub(super) struct RemovedParams {
    surface: SurfaceId,
    reason: String,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    origin: Option<String>,
    #[serde(default)]
    mutation_id: Option<String>,
}

/// Why the owner removed a tab: it answered a close request, the user
/// closed it in the app, the page closed itself, or an extension removed it.
const REMOVAL_REASONS: [&str; 4] = ["answered", "user_closed", "page_closed", "extension"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    /// Asked; the owner has not answered.
    Asked,
    /// The owner started the close; the tab goes on its removal report.
    Closing,
}

struct Subscriber {
    owner: String,
    writer: MessageWriter,
}

struct Waiter {
    client: u64,
    writer: MessageWriter,
}

struct OpenClose {
    surface: SurfaceId,
    owner_client: u64,
    /// The owner connection, told when the request times out.
    owner_writer: MessageWriter,
    phase: Phase,
    /// The owner must answer by then; only an `Asked` request times out.
    deadline: Instant,
    waiters: Vec<Waiter>,
}

#[derive(Default)]
struct State {
    subscribers: BTreeMap<u64, Subscriber>,
    /// The connection that answers for each owner (the newest subscriber).
    owners: HashMap<String, u64>,
    open: HashMap<String, OpenClose>,
    /// Set when the broker is dropped; the deadline thread then exits.
    shut_down: bool,
}

impl State {
    /// The live connection subscribed for `owner`, if any.
    fn owner_connection(&self, owner: &str) -> Option<(u64, MessageWriter)> {
        let client = *self.owners.get(owner)?;
        let subscriber = self.subscribers.get(&client)?;
        subscriber.writer.is_open().then(|| (client, subscriber.writer.clone()))
    }

    fn open_for_surface(&self, surface: SurfaceId) -> Option<String> {
        self.open.iter().find(|(_, open)| open.surface == surface).map(|(id, _)| id.clone())
    }

    /// The first deadline of a request that the owner has not answered.
    fn next_deadline(&self) -> Option<Instant> {
        self.open.values().filter(|open| open.phase == Phase::Asked).map(|open| open.deadline).min()
    }

    /// Removes the requests `matches` selects and returns them, to be
    /// settled after the lock is released.
    fn take(&mut self, matches: impl Fn(&OpenClose) -> bool) -> Vec<(String, OpenClose)> {
        let ids: Vec<String> =
            self.open.iter().filter(|(_, open)| matches(open)).map(|(id, _)| id.clone()).collect();
        ids.into_iter().filter_map(|id| self.open.remove(&id).map(|open| (id, open))).collect()
    }
}

/// Settles `removed` the open requests whose tab left the store by another
/// path (`close-surface`, `close-tabs`, `close-pane`, a workspace close):
/// no removal report comes for them, and they would hold the per-owner
/// request budget until the owner disconnects.
fn settle_gone_tabs(mux: &Mux) {
    let closes = &mux.control_clients.frontend_tab_closes;
    let surfaces: Vec<SurfaceId> = closes.state().open.values().map(|open| open.surface).collect();
    let gone: Vec<SurfaceId> = surfaces
        .into_iter()
        .filter(|surface| mux.surface(*surface).is_none_or(|live| live.is_dead()))
        .collect();
    if gone.is_empty() {
        return;
    }
    let settled = closes.state().take(|open| gone.contains(&open.surface));
    settle(settled, "removed");
}

/// A poisoned lock still guards whole entries (no critical section leaves
/// one half changed), so the broker keeps working.
fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

fn settled_event(request_id: &str, surface: SurfaceId, outcome: &str) -> Value {
    json!({
        "event": "frontend-browser-tab-close-settled",
        "request_id": request_id,
        "surface": surface,
        "outcome": outcome,
    })
}

/// Tells every requester how its close ended. Best effort: a requester
/// whose connection closed meanwhile has nobody to tell.
fn settle(settled: Vec<(String, OpenClose)>, outcome: &str) {
    for (request_id, open) in settled {
        let event = settled_event(&request_id, open.surface, outcome);
        for waiter in open.waiters {
            let _ = waiter.writer.send_control(&event);
        }
    }
}

/// Settles `timed_out` the requests whose owner did not answer in time. The
/// owner gets the settled event too: it must now close the tab without a
/// beforeunload veto and report the removal. A requester that is also the
/// owner connection gets the event once.
fn settle_timed_out(settled: Vec<(String, OpenClose)>) {
    for (request_id, open) in settled {
        let event = settled_event(&request_id, open.surface, "timed_out");
        if !open.waiters.iter().any(|waiter| waiter.client == open.owner_client) {
            let _ = open.owner_writer.send_control(&event);
        }
        for waiter in open.waiters {
            let _ = waiter.writer.send_control(&event);
        }
    }
}

#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    /// Wakes the deadline thread when a request or a shutdown changes the
    /// next deadline.
    wake: Condvar,
}

/// One thread per broker settles the requests whose deadline passed. It
/// sleeps until the first deadline and exits when the broker is dropped.
fn run_deadlines(shared: &Shared) {
    let mut state = lock(&shared.state);
    loop {
        if state.shut_down {
            return;
        }
        let now = Instant::now();
        let expired = state.take(|open| open.phase == Phase::Asked && open.deadline <= now);
        if !expired.is_empty() {
            drop(state);
            settle_timed_out(expired);
            state = lock(&shared.state);
            continue;
        }
        state = match state.next_deadline() {
            Some(deadline) => {
                shared
                    .wake
                    .wait_timeout(state, deadline.saturating_duration_since(now))
                    .unwrap_or_else(PoisonError::into_inner)
                    .0
            }
            None => shared.wake.wait(state).unwrap_or_else(PoisonError::into_inner),
        };
    }
}

#[derive(Default)]
pub(crate) struct FrontendTabCloses {
    shared: Arc<Shared>,
    deadline_thread: OnceLock<()>,
}

impl Drop for FrontendTabCloses {
    fn drop(&mut self) {
        lock(&self.shared.state).shut_down = true;
        self.shared.wake.notify_all();
    }
}

impl FrontendTabCloses {
    fn state(&self) -> MutexGuard<'_, State> {
        lock(&self.shared.state)
    }

    /// Starts the deadline thread on the first delegated request, then
    /// wakes it for the new deadline.
    fn watch_deadlines(&self) {
        self.deadline_thread.get_or_init(|| {
            let shared = Arc::clone(&self.shared);
            let started = std::thread::Builder::new()
                .name("frontend-tab-close-deadlines".into())
                .spawn(move || run_deadlines(&shared));
            if let Err(error) = started {
                // Without the thread no request times out; the other
                // outcomes still settle.
                eprintln!(
                    "cmux-tui: frontend tab close: cannot start the deadline thread: {error}"
                );
            }
        });
        self.shared.wake.notify_all();
    }

    fn subscribe(&self, client: u64, owner: String, writer: MessageWriter) -> anyhow::Result<()> {
        let mut state = self.state();
        anyhow::ensure!(
            state.subscribers.len() < MAX_SUBSCRIBERS || state.subscribers.contains_key(&client),
            "too many frontend browser close subscribers"
        );
        if let Some(previous) = state.subscribers.remove(&client)
            && state.owners.get(&previous.owner) == Some(&client)
        {
            state.owners.remove(&previous.owner);
        }
        // The newest connection for an owner answers from now on; requests
        // already sent to an older one stay with it until it answers or ends.
        state.owners.insert(owner.clone(), client);
        state.subscribers.insert(client, Subscriber { owner, writer });
        Ok(())
    }

    /// The connection ended: it stops answering for its owner, the requests
    /// it holds settle `owner_gone` (the tabs stay), and it stops waiting
    /// on its own requests.
    pub(super) fn disconnect(&self, client: u64) {
        let gone = {
            let mut state = self.state();
            if let Some(subscriber) = state.subscribers.remove(&client)
                && state.owners.get(&subscriber.owner) == Some(&client)
            {
                state.owners.remove(&subscriber.owner);
            }
            for open in state.open.values_mut() {
                open.waiters.retain(|waiter| waiter.client != client);
            }
            state.take(|open| open.owner_client == client)
        };
        settle(gone, "owner_gone");
    }
}

#[derive(Debug)]
struct OriginForbidden(&'static str);

impl std::fmt::Display for OriginForbidden {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for OriginForbidden {}

/// The `error_code` of a refused close-request command.
pub(super) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<OriginForbidden>().map(|_| ORIGIN_FORBIDDEN.to_string())
}

/// The owner path is the hosting app's own connection, never a page relay
/// (a page must not decide another tab's existence).
fn refuse_page_relay(mux: &Mux, client: u64) -> anyhow::Result<()> {
    let state = mux.control_clients.state.lock().unwrap_or_else(PoisonError::into_inner);
    let page_relay =
        state.clients.get(&client).is_some_and(|record| record.origin.role == HelloRole::PageRelay);
    if page_relay {
        Err(OriginForbidden("a page relay connection may not own frontend browser tabs").into())
    } else {
        Ok(())
    }
}

/// The live frontend browser tab `surface` and its owner.
fn frontend_tab(mux: &Mux, surface: SurfaceId) -> anyhow::Result<(Option<String>, Option<String>)> {
    let Some(live) = mux.surface(surface).filter(|live| !live.is_dead()) else {
        anyhow::bail!("unknown surface {surface}");
    };
    let Some(record) = mux.frontend_browser(&live) else {
        anyhow::bail!("surface {surface} is not a frontend browser tab");
    };
    let tab = live.resource_identity().map(|identity| identity.tab_id.as_str().to_string());
    Ok((record.owner, tab))
}

pub(super) fn subscribe(
    mux: &Mux,
    client: u64,
    params: SubscribeParams,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    refuse_page_relay(mux, client)?;
    anyhow::ensure!(
        valid_install_id(&params.owner),
        "bad request: owner must be 1-128 characters of A-Z a-z 0-9 _ -"
    );
    mux.control_clients.frontend_tab_closes.subscribe(client, params.owner, writer.clone())?;
    Ok(json!({"close_requests_ready": true}))
}

pub(super) fn request(
    mux: &Mux,
    client: u64,
    params: RequestParams,
    writer: &MessageWriter,
) -> anyhow::Result<Value> {
    // A page must not close another tab, even through its owner.
    refuse_page_relay(mux, client)?;
    let RequestParams { surface, reason, deadline_ms } = params;
    anyhow::ensure!(
        (1..=MAX_DEADLINE_MS).contains(&deadline_ms),
        "bad request: deadline_ms must be 1-{MAX_DEADLINE_MS}"
    );
    let (owner, tab) = frontend_tab(mux, surface)?;
    settle_gone_tabs(mux);
    let not_delegated = json!({"delegated": false, "request_id": null});
    let Some(owner) = owner else { return Ok(not_delegated) };
    let closes = &mux.control_clients.frontend_tab_closes;
    let mut state = closes.state();
    let waiter = Waiter { client, writer: writer.clone() };
    // One close per tab at a time: a second request waits on the first.
    if let Some(request_id) = state.open_for_surface(surface)
        && let Some(open) = state.open.get_mut(&request_id)
    {
        if !open.waiters.iter().any(|existing| existing.client == client) {
            anyhow::ensure!(
                open.waiters.len() < MAX_WAITERS_PER_REQUEST,
                "too many requests wait on this tab's close"
            );
            open.waiters.push(waiter);
        }
        return Ok(json!({"delegated": true, "request_id": request_id}));
    }
    let Some((owner_client, owner_writer)) = state.owner_connection(&owner) else {
        return Ok(not_delegated);
    };
    anyhow::ensure!(
        state.open.values().filter(|open| open.owner_client == owner_client).count()
            < MAX_OPEN_PER_OWNER,
        "too many open close requests for this tab's owner"
    );
    let request_id = crate::workspace_registry::new_uuid_v4();
    let event = json!({
        "event": "frontend-browser-tab-close-requested",
        "request_id": request_id,
        "surface": surface,
        "owner": owner,
        "tab_resource_id": tab,
        "reason": reason.map(crate::mux::CloseReason::as_str),
    });
    if owner_writer.send_control(&event).is_err() {
        // The owner's connection just closed; its disconnect cleans up.
        return Ok(not_delegated);
    }
    state.open.insert(
        request_id.clone(),
        OpenClose {
            surface,
            owner_client,
            owner_writer,
            phase: Phase::Asked,
            deadline: Instant::now() + Duration::from_millis(deadline_ms),
            waiters: vec![waiter],
        },
    );
    drop(state);
    closes.watch_deadlines();
    Ok(json!({"delegated": true, "request_id": request_id}))
}

pub(super) fn answer(mux: &Mux, client: u64, params: AnswerParams) -> anyhow::Result<Value> {
    let AnswerParams { request_id, outcome } = params;
    let cancelled = match outcome.as_str() {
        "closing" => false,
        "cancelled" => true,
        other => {
            anyhow::bail!("bad request: outcome {other:?} (want \"closing\" or \"cancelled\")")
        }
    };
    let settled = {
        let mut state = mux.control_clients.frontend_tab_closes.state();
        let phase = match state.open.get(&request_id) {
            Some(open) if open.owner_client == client => open.phase,
            _ => return Ok(json!({"accepted": false})),
        };
        match (phase, cancelled) {
            // A page may veto after its close started (beforeunload).
            (Phase::Asked | Phase::Closing, true) => {
                state.open.remove(&request_id).map(|open| (request_id, open))
            }
            (Phase::Asked, false) => {
                if let Some(open) = state.open.get_mut(&request_id) {
                    open.phase = Phase::Closing;
                }
                None
            }
            (Phase::Closing, false) => return Ok(json!({"accepted": false})),
        }
    };
    settle(settled.into_iter().collect(), "cancelled");
    Ok(json!({"accepted": true}))
}

pub(super) fn report_removed(
    mux: &Mux,
    client: u64,
    params: RemovedParams,
) -> anyhow::Result<Value> {
    refuse_page_relay(mux, client)?;
    let RemovedParams { surface, reason, request_id, origin, mutation_id } = params;
    anyhow::ensure!(
        REMOVAL_REASONS.contains(&reason.as_str()),
        "bad request: reason {reason:?} (want \"answered\", \"user_closed\", \"page_closed\" or \"extension\")"
    );
    let request =
        MutationRequest { origin, mutation_id, expected_generation: None, expected_revision: None };
    let keyed = request.mutation_id.is_some();
    let mutation = workspace_mutation(mux, client, &request)?;
    let closes = &mux.control_clients.frontend_tab_closes;
    let live = mux.surface(surface).filter(|live| !live.is_dead());
    match live {
        Some(live) => {
            let Some(record) = mux.frontend_browser(&live) else {
                anyhow::bail!("surface {surface} is not a frontend browser tab");
            };
            let owns = record.owner.as_deref().is_some_and(|owner| {
                let state = closes.state();
                state.owners.get(owner) == Some(&client)
                    && state.subscribers.get(&client).is_some_and(|sub| sub.owner == owner)
            });
            if !owns {
                return Err(OriginForbidden(
                    "only the tab owner's subscribed connection may report its removal",
                )
                .into());
            }
        }
        // Gone already: a keyed retry replays the committed close; anything
        // else has nothing to remove.
        None => {
            let reply = if keyed {
                match mux.close_tabs_for(vec![surface], false, None, &mutation) {
                    Ok(outcome) => json!({
                        "removed": outcome.closed().contains(&surface),
                        "replayed": outcome.replayed,
                    }),
                    Err(_) => json!({"removed": false, "replayed": false}),
                }
            } else {
                json!({"removed": false, "replayed": false})
            };
            settle_gone_tabs(mux);
            return Ok(reply);
        }
    }
    if let Some(request_id) = &request_id {
        let other_tab =
            closes.state().open.get(request_id).is_some_and(|open| open.surface != surface);
        anyhow::ensure!(
            !other_tab,
            "bad request: request_id {request_id} is a close request for another tab"
        );
    }
    let outcome = mux.close_tabs_for(vec![surface], false, None, &mutation)?;
    let removed = outcome.closed().contains(&surface);
    if removed {
        // A removal settles every open request for this tab, the named one
        // and any other that was still waiting (a tab the page or an
        // extension removed on its own).
        let settled = closes.state().take(|open| open.surface == surface);
        settle(settled, "removed");
    }
    Ok(json!({"removed": removed, "replayed": outcome.replayed}))
}
