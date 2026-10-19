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
//! `close-surface`), `cancelled`, or `owner_gone` (the owner's connection
//! ended; the tab stays, and the owner restores it when it comes back). Crash and
//! discard are not removals; the owner reports them through
//! `update-frontend-browser-tab`. Requests are transient: they are never
//! journaled or replayed across a daemon restart.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, MutexGuard, PoisonError};

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
    phase: Phase,
    waiters: Vec<Waiter>,
}

#[derive(Default)]
struct State {
    subscribers: BTreeMap<u64, Subscriber>,
    /// The connection that answers for each owner (the newest subscriber).
    owners: HashMap<String, u64>,
    open: HashMap<String, OpenClose>,
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
    let surfaces: Vec<SurfaceId> = lock(&closes.0).open.values().map(|open| open.surface).collect();
    let gone: Vec<SurfaceId> = surfaces
        .into_iter()
        .filter(|surface| mux.surface(*surface).is_none_or(|live| live.is_dead()))
        .collect();
    if gone.is_empty() {
        return;
    }
    let settled = lock(&closes.0).take(|open| gone.contains(&open.surface));
    settle(settled, "removed");
}

/// A poisoned lock still guards whole entries (no critical section leaves
/// one half changed), so the broker keeps working.
fn lock(state: &Mutex<State>) -> MutexGuard<'_, State> {
    state.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Tells every requester how its close ended. Best effort: a requester
/// whose connection closed meanwhile has nobody to tell.
fn settle(settled: Vec<(String, OpenClose)>, outcome: &str) {
    for (request_id, open) in settled {
        for waiter in open.waiters {
            let _ = waiter.writer.send_control(&json!({
                "event": "frontend-browser-tab-close-settled",
                "request_id": request_id,
                "surface": open.surface,
                "outcome": outcome,
            }));
        }
    }
}

#[derive(Default)]
pub(crate) struct FrontendTabCloses(Mutex<State>);

impl FrontendTabCloses {
    fn subscribe(&self, client: u64, owner: String, writer: MessageWriter) -> anyhow::Result<()> {
        let mut state = lock(&self.0);
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
            let mut state = lock(&self.0);
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
    let RequestParams { surface, reason } = params;
    let (owner, tab) = frontend_tab(mux, surface)?;
    settle_gone_tabs(mux);
    let not_delegated = json!({"delegated": false, "request_id": null});
    let Some(owner) = owner else { return Ok(not_delegated) };
    let mut state = lock(&mux.control_clients.frontend_tab_closes.0);
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
        OpenClose { surface, owner_client, phase: Phase::Asked, waiters: vec![waiter] },
    );
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
        let mut state = lock(&mux.control_clients.frontend_tab_closes.0);
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
                let state = lock(&closes.0);
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
            lock(&closes.0).open.get(request_id).is_some_and(|open| open.surface != surface);
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
        let settled = lock(&closes.0).take(|open| open.surface == surface);
        settle(settled, "removed");
    }
    Ok(json!({"removed": removed, "replayed": outcome.replayed}))
}
