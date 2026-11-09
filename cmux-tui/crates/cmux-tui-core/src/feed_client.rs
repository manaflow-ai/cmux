//! The daemon's feed client (`feed-client-v1`, plans/cmux-next/feed-page.md):
//! the one mirror of the person's feed that Swift's `CmuxNextFeed` held, so
//! the React Feed page and native callers read it through `feed.*` ops.
//!
//! Owner role: none of the feed's data is the daemon's. The user's
//! `FeedDO` owns cloud items (this client mirrors them over
//! `/v1/wire/feed` on the app's cloud lease); the in-memory integration
//! owner here owns GitHub items and update cards, as the app's in-memory
//! owner did; acpmux owns the reports mailbox. What this module keeps is
//! client state: the mirror, the pending intents, ETags, GitHub details and
//! the reports window, all in memory.
//!
//! Threads, each with its stop condition (`shutdown`, called from
//! `Mux::shutdown`): the cloud driver (started on the first `feed.*` call
//! when the daemon has a cloud link; it waits on the socket, a backoff or a
//! new lease), the GitHub poller (only while the connection is enabled;
//! each pass waits the interval or a wakeup) and the reports reader (each
//! pass is one acpmux mailbox wait; failures back off, then wait for a
//! wakeup). Nothing polls the page: readers hear `feed-view-changed` and
//! `feed-reports-changed`.

mod driver;
mod github;
mod reports;

use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use cmux_feed_core::client::github::GitHubSync;
use cmux_feed_core::client::{
    CloudStream, Commit, FeedItem, IntegrationOwner, Intent, IntentKind, Mirror, Owner, OwnerEvent,
    Place, Posted, Prompt, Reject, Reports, ViewAccount, ViewContext, ViewRequest,
    normalize_choice,
};
use serde_json::{Value, json};

pub use github::{GhRunner, ProcessGh};
pub use reports::Mailbox;

use crate::cloud_conversations::{CloudConversations, WireInterrupt};

/// Advertised by `identify` once the daemon serves the `feed.*` ops.
pub const FEED_CLIENT_CAPABILITY: &str = "feed-client-v1";
/// The device name an answer's overlay names (the owner records its own).
const DEVICE: &str = "Mac";
/// How long a `feed.intent` waits for its settle line.
pub const SETTLE_TIMEOUT: Duration = Duration::from_secs(15);
/// Settled intent keys remembered, so a retry of one answers again.
const RECENT_SETTLES: usize = 128;

/// What the client tells subscribers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FeedEvent {
    /// `feed-view-changed`: anything shown changed; `changed` names the
    /// items whose confirmed or visible value moved (empty for a connection
    /// change alone).
    View { revision: u64, changed: Vec<String> },
    /// `feed-reports-changed`.
    Reports { revision: u64 },
}

/// Sends a report reply to an acpmux session (`acpmux send --no-wait
/// --no-steer --prompt-id <id> -- <session> -`, the text on stdin); true
/// when acpmux took it. The binary installs it.
pub type ReplySender = Arc<dyn Fn(&str, &str, &str) -> bool + Send + Sync>;

/// One read's lookup of an item's agent, workspace and tab: built from the
/// daemon's store once per read, before the feed state lock, so naming the
/// rows costs one pass over the tabs per read and no store lock is taken
/// while the feed's is held.
pub type Places = Box<dyn Fn(&FeedItem) -> Option<Place> + Send>;

/// Snapshots the daemon's store into a [`Places`] lookup for one read.
pub type PlaceResolver = Arc<dyn Fn() -> Places + Send + Sync>;

/// What the client reads from its host.
pub struct FeedDeps {
    pub cloud: Option<CloudConversations>,
    pub gh: Arc<dyn GhRunner>,
    pub mailbox: Arc<dyn Mailbox>,
    pub sink: Arc<dyn Fn(FeedEvent) + Send + Sync>,
    pub now_ms: Arc<dyn Fn() -> i64 + Send + Sync>,
    /// Snapshots the daemon's store for naming an item's agent, workspace
    /// and tab (called once per read, with no feed lock held).
    pub place: PlaceResolver,
}

/// The GitHub connection's setting (`feed.github.configure`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GitHubConfig {
    pub enabled: bool,
    pub interval_s: u64,
}

pub(crate) struct State {
    pub(crate) mirror: Mirror,
    pub(crate) owner: IntegrationOwner,
    pub(crate) stream: CloudStream,
    /// Frames for the cloud socket, sent by the driver.
    pub(crate) outbox: Vec<String>,
    /// Ends the driver's pending receive (a frame waits in the outbox).
    pub(crate) wire_wake: Option<WireInterrupt>,
    /// The account the cloud part belongs to (the welcome's user).
    pub(crate) account: Option<String>,
    /// The person of the lease the account was read on (`driver::lease_identity`).
    pub(crate) lease_identity: Option<String>,
    /// That person's user id (the lease's account), when the lease names one.
    pub(crate) lease_user: Option<String>,
    pub(crate) github: GitHubSync,
    pub(crate) github_config: GitHubConfig,
    /// Bumped by every configure, refresh and account change: the poller's
    /// wait ends on it.
    pub(crate) github_generation: u64,
    /// Bumped on every account change and configure: a poll answer read
    /// before it is dropped, so the old account's rows, or rows of a poller
    /// turned off, never come back.
    pub(crate) github_epoch: u64,
    pub(crate) github_running: bool,
    pub(crate) github_error: Option<String>,
    pub(crate) reports: Reports,
    /// Bumped on every account change and wakeup: the reader's wait ends.
    pub(crate) reports_generation: u64,
    /// Bumped whenever the basket is emptied for an account or lease change:
    /// the reader starts over from cursor 0 and drops a page read before.
    pub(crate) reports_epoch: u64,
    /// The app's active state as the owner hears it: true while any
    /// verified frontend connection that set it active is still open.
    pub(crate) presence: bool,
    /// The frontend connections whose last `feed.presence.set` was active.
    /// A connection that closes without saying inactive (the app crashed)
    /// leaves this set; the owner hears inactive when the last one goes.
    pub(crate) presence_holders: HashSet<u64>,
    waiters: HashMap<String, Vec<SyncSender<Result<(), Reject>>>>,
    recent: VecDeque<(String, Result<(), Reject>)>,
    started: bool,
}

pub(crate) struct Inner {
    pub(crate) state: Mutex<State>,
    /// Wakes the poller and the reader (paired with `state`).
    pub(crate) wake: Condvar,
    pub(crate) deps: FeedDeps,
    pub(crate) shutdown: AtomicBool,
    reply: Mutex<Option<ReplySender>>,
}

/// The daemon's feed client. Cheap to clone.
#[derive(Clone)]
pub struct FeedClient {
    pub(crate) inner: Arc<Inner>,
}

/// One refusal of a `feed.*` op: the owner's or this client's code.
#[derive(Clone, Debug, PartialEq)]
pub enum FeedError {
    Invalid(String),
    Rejected(Reject),
    /// A caller other than the verified app.
    Forbidden(&'static str),
    Unavailable(String),
}

impl Inner {
    pub(crate) fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(crate) fn now(&self) -> i64 {
        (self.deps.now_ms)()
    }

    pub(crate) fn stopped(&self) -> bool {
        self.shutdown.load(Ordering::SeqCst)
    }

    pub(crate) fn emit(&self, events: Vec<FeedEvent>) {
        for event in events {
            (self.deps.sink)(event);
        }
    }

    /// Owner events of the integration owner into the mirror.
    pub(crate) fn local_events(
        state: &mut State,
        events: Vec<OwnerEvent>,
        now: i64,
    ) -> Vec<FeedEvent> {
        events
            .into_iter()
            .filter_map(|event| {
                state.mirror.event(
                    Owner::Local,
                    event.items,
                    event.removed,
                    event.tx.as_deref(),
                    now,
                )
            })
            .map(view_event)
            .collect()
    }

    /// One owner's settle line for `key`; resolves the waiters once every
    /// owner it went to settled.
    pub(crate) fn settle(
        state: &mut State,
        key: &str,
        reject: Option<Reject>,
        now: i64,
    ) -> Vec<FeedEvent> {
        let (commit, outcome) = state.mirror.settle(key, reject, now);
        if let Some(outcome) = outcome {
            for waiter in state.waiters.remove(key).unwrap_or_default() {
                let _ = waiter.try_send(outcome.clone());
            }
            state.recent.push_back((key.to_owned(), outcome));
            while state.recent.len() > RECENT_SETTLES {
                state.recent.pop_front();
            }
        }
        commit.into_iter().map(view_event).collect()
    }

    /// Frames go out at once: the driver's receive ends early.
    pub(crate) fn wake_wire(state: &State) {
        if let Some(wake) = &state.wire_wake {
            wake();
        }
    }
}

pub(crate) fn view_event(commit: Commit) -> FeedEvent {
    FeedEvent::View { revision: commit.revision, changed: commit.changed }
}

/// What a `feed.intent` answers: now, or once its settle line arrives.
pub enum IntentReply {
    Now(Result<(), Reject>),
    Wait(Receiver<Result<(), Reject>>),
}

impl IntentReply {
    /// The outcome, waiting at most [`SETTLE_TIMEOUT`]; `None` when no
    /// owner settled it in time (it stays pending and shown).
    pub fn wait(self) -> Option<Result<(), Reject>> {
        match self {
            IntentReply::Now(outcome) => Some(outcome),
            IntentReply::Wait(receiver) => receiver.recv_timeout(SETTLE_TIMEOUT).ok(),
        }
    }
}

fn strings(value: Option<&Value>) -> Option<Vec<String>> {
    value?.as_array()?.iter().map(|id| id.as_str().map(str::to_owned)).collect()
}

impl FeedClient {
    pub fn new(deps: FeedDeps) -> Self {
        let state = State {
            mirror: Mirror::new(DEVICE),
            owner: IntegrationOwner::new(DEVICE),
            stream: CloudStream::new(),
            outbox: Vec::new(),
            wire_wake: None,
            account: None,
            lease_identity: None,
            lease_user: None,
            github: GitHubSync::new(),
            github_config: GitHubConfig {
                enabled: false,
                interval_s: cmux_feed_core::client::github::DEFAULT_INTERVAL_S,
            },
            github_generation: 0,
            github_epoch: 0,
            github_running: false,
            github_error: None,
            reports: Reports::default(),
            reports_generation: 0,
            reports_epoch: 0,
            presence: false,
            presence_holders: HashSet::new(),
            waiters: HashMap::new(),
            recent: VecDeque::new(),
            started: false,
        };
        Self {
            inner: Arc::new(Inner {
                state: Mutex::new(state),
                wake: Condvar::new(),
                deps,
                shutdown: AtomicBool::new(false),
                reply: Mutex::new(None),
            }),
        }
    }

    /// Starts the cloud driver and the reports reader once (the first
    /// `feed.*` call does this).
    pub fn ensure_started(&self) {
        {
            let mut state = self.inner.lock();
            if state.started || self.inner.stopped() {
                return;
            }
            state.started = true;
        }
        if self.inner.deps.cloud.is_some() {
            driver::start(&self.inner);
        }
        reports::start(&self.inner);
    }

    /// Stops every thread of the client: each ends at its next wakeup,
    /// which this sends.
    pub fn shutdown(&self) {
        self.inner.shutdown.store(true, Ordering::SeqCst);
        let state = self.inner.lock();
        Inner::wake_wire(&state);
        drop(state);
        self.inner.wake.notify_all();
        if let Some(cloud) = &self.inner.deps.cloud {
            cloud.wake_lease_waiters();
        }
    }

    /// The lease changed (`cloud-session-set`, `cloud-session-clear`):
    /// another person's lease takes the old account's state away now, not
    /// when the socket's receive ends, and the receive ends at once so the
    /// driver reconnects on the new lease.
    pub fn lease_changed(&self) {
        if let Some(cloud) = &self.inner.deps.cloud {
            driver::forget_other_lease(&self.inner, cloud);
        }
        Inner::wake_wire(&self.inner.lock());
    }

    pub fn set_reply_sender(&self, sender: Option<ReplySender>) {
        *self.inner.reply.lock().unwrap_or_else(PoisonError::into_inner) = sender;
    }

    // MARK: Reads

    /// `feed.view.read`.
    pub fn view(&self, request: &ViewRequest) -> Value {
        self.ensure_started();
        let now = self.inner.now();
        let places = self.places(true);
        let mut state = self.inner.lock();
        // A snooze that ended shows again with this read.
        let woke: Vec<FeedEvent> = state.mirror.tick(now).into_iter().map(view_event).collect();
        let view = self.context(&state, now, &places, |context| context.view(request));
        drop(state);
        self.inner.emit(woke);
        view
    }

    /// The store's place lookup for one read (none when the read shows no
    /// rows). Taken before the feed state lock.
    fn places(&self, rows: bool) -> Places {
        if rows { (self.inner.deps.place)() } else { Box::new(|_| None) }
    }

    fn context<T>(
        &self,
        state: &State,
        now: i64,
        places: &Places,
        read: impl FnOnce(&ViewContext<'_>) -> T,
    ) -> T {
        let place = |item: &FeedItem| places(item);
        // Signed out the view is no one's, whatever lease was read last.
        let signed_out = state.mirror.connection().reason() == Some("signed_out");
        let account = state
            .lease_identity
            .as_deref()
            .filter(|_| !signed_out)
            .map(|id| ViewAccount { id, user: state.lease_user.as_deref() });
        let context = ViewContext {
            mirror: &state.mirror,
            account,
            now,
            github: Some(&state.github),
            github_enabled: state.github_config.enabled,
            reports_available: reports::person(&self.inner, state.account.as_deref()).is_some()
                && self.inner.deps.mailbox.available(),
            place: &place,
        };
        read(&context)
    }

    /// `feed.item.get`: view items, or with `confirmed` the owners' items
    /// without this client's overlay.
    pub fn items(&self, ids: &[String], confirmed: bool) -> Vec<Value> {
        self.ensure_started();
        let now = self.inner.now();
        let places = self.places(!confirmed);
        let state = self.inner.lock();
        self.context(&state, now, &places, |context| {
            ids.iter()
                .filter_map(|id| {
                    if confirmed {
                        state.mirror.confirmed(id).map(FeedItem::to_value)
                    } else {
                        state.mirror.visible(id).map(|item| context.item(item))
                    }
                })
                .collect()
        })
    }

    /// `feed.items.list`: every item matching `state` (`open`, `closed`)
    /// and `home` (`cloud`, `local`), newest first.
    pub fn list(&self, lifecycle: Option<&str>, home: Option<&str>, confirmed: bool) -> Vec<Value> {
        self.ensure_started();
        let now = self.inner.now();
        let places = self.places(!confirmed);
        let state = self.inner.lock();
        let keep = |item: &FeedItem| {
            let lifecycle = match lifecycle {
                Some("open") => !item.state.is_closed(),
                Some("closed") => item.state.is_closed(),
                _ => true,
            };
            let home = match home {
                Some("cloud") => !item.is_local(),
                Some("local") => item.is_local(),
                _ => true,
            };
            lifecycle && home
        };
        self.context(&state, now, &places, |context| {
            state
                .mirror
                .timeline()
                .filter_map(|item| {
                    let item = if confirmed { state.mirror.confirmed(&item.id)? } else { item };
                    keep(item).then(|| if confirmed { item.to_value() } else { context.item(item) })
                })
                .collect()
        })
    }

    // MARK: Intents

    /// `feed.intent`: logs the intent (shown at once), sends it to its
    /// owners and answers once they settled it.
    pub fn intent(&self, key: &str, params: &Value) -> Result<IntentReply, FeedError> {
        self.ensure_started();
        let now = self.inner.now();
        let mut events = Vec::new();
        let reply = {
            let mut state = self.inner.lock();
            if let Some((_, outcome)) = state.recent.iter().find(|(sent, _)| sent == key) {
                return Ok(IntentReply::Now(outcome.clone()));
            }
            let (sender, receiver) = sync_channel(1);
            if state.mirror.has_pending(key) {
                state.waiters.entry(key.to_owned()).or_default().push(sender);
                return Ok(IntentReply::Wait(receiver));
            }
            let Some(intent) = Self::parse_intent(&state, key, params, now)? else {
                return Ok(IntentReply::Now(Ok(())));
            };
            let live = state.stream.is_live();
            let (commit, routed) = state.mirror.begin(intent, live, now);
            events.push(view_event(commit));
            state.waiters.entry(key.to_owned()).or_default().push(sender);
            if routed.refused {
                events.extend(Inner::settle(&mut state, key, Some(Reject::Disconnected), now));
            }
            if let Some(local) = routed.local {
                let (outcome, owner_events) = state.owner.commit(&local);
                events.extend(Inner::local_events(&mut state, owner_events, now));
                events.extend(Inner::settle(&mut state, key, outcome.err(), now));
            }
            if let Some(cloud) = routed.cloud {
                match state.stream.send(&cloud) {
                    Ok(Some(frame)) => {
                        state.outbox.push(frame);
                        Inner::wake_wire(&state);
                    }
                    Ok(None) => events.extend(Inner::settle(&mut state, key, None, now)),
                    Err(reject) => events.extend(Inner::settle(&mut state, key, Some(reject), now)),
                }
            }
            IntentReply::Wait(receiver)
        };
        self.inner.emit(events);
        Ok(reply)
    }

    /// The intent of `params`, checked against the item as shown (Swift
    /// `FeedModel.answer`, `markRead`, `archive`, `snooze`,
    /// `markAllRead`); `None` when nothing is left to send.
    fn parse_intent(
        state: &State,
        key: &str,
        params: &Value,
        now: i64,
    ) -> Result<Option<Intent>, FeedError> {
        let invalid = |message: &str| FeedError::Invalid(message.to_owned());
        let kind = params
            .get("kind")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid("kind is required"))?;
        let item_id = || {
            params
                .get("item")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| invalid("item is required"))
        };
        let items = || {
            let ids = strings(params.get("items"))
                .ok_or_else(|| invalid("items must be a list of item ids"))?;
            // The cloud owner takes at most 256 ids per op (FeedWireEncode), so the intent does too:
            // a longer one would show every id changed and send only the first 256.
            if ids.is_empty() || ids.len() > cmux_feed_core::client::MAX_INTENT_IDS {
                return Err(invalid("items takes 1 to 256 item ids"));
            }
            Ok(ids)
        };
        let request = |id: &str| -> Result<&FeedItem, FeedError> {
            let item = state.mirror.visible(id).ok_or_else(|| invalid("no such item"))?;
            if !item.is_request() {
                return Err(invalid("the item is a notice, not a request"));
            }
            if item.state.is_closed() {
                return Err(FeedError::Rejected(Reject::Closed(Box::new(item.clone()))));
            }
            Ok(item)
        };
        let shown = |ids: Vec<String>, keep: &dyn Fn(&FeedItem) -> bool| -> Vec<String> {
            ids.into_iter().filter(|id| state.mirror.visible(id).is_some_and(keep)).collect()
        };
        let kind = match kind {
            "answer" => {
                let id = item_id()?;
                let item = request(&id)?;
                let mut value =
                    params.get("answer").cloned().ok_or_else(|| invalid("answer is required"))?;
                if let Prompt::Choice { questions } = Prompt::parse(&item.kind, &item.prompt) {
                    value = normalize_choice(&value, &questions).map_err(|issues| {
                        FeedError::Invalid(format!(
                            "the choice answer is not complete: {}",
                            json!(issues)
                        ))
                    })?;
                }
                IntentKind::Answer { item: id, value }
            }
            "decline" => {
                let id = item_id()?;
                request(&id)?;
                IntentKind::Decline { item: id }
            }
            "read" => IntentKind::Read { items: shown(items()?, &FeedItem::is_unread) },
            "archive" => IntentKind::Archive {
                items: shown(items()?, &|item| !item.is_open_request() && !item.is_archived()),
            },
            "snooze" => {
                let until = params
                    .get("until")
                    .and_then(Value::as_i64)
                    .ok_or_else(|| invalid("until (Unix ms) is required"))?;
                IntentKind::Snooze {
                    items: shown(items()?, &|item| !item.is_open_request()),
                    until,
                }
            }
            "mark_all_read" => {
                if state.mirror.counts().unread == 0 {
                    return Ok(None);
                }
                IntentKind::MarkAllRead {
                    before: params.get("before").and_then(Value::as_i64).unwrap_or(now),
                }
            }
            _ => {
                return Err(invalid(
                    "kind must be answer, decline, read, archive, snooze or mark_all_read",
                ));
            }
        };
        let empty = matches!(&kind, IntentKind::Read { items } | IntentKind::Archive { items } | IntentKind::Snooze { items, .. } if items.is_empty());
        Ok((!empty).then(|| Intent::new(key, kind, now)))
    }

    // MARK: Integration owner

    /// `feed.post`: into the integration owner (dedupe by key).
    pub fn post(&self, item: FeedItem) -> Posted {
        self.ensure_started();
        let now = self.inner.now();
        let (posted, events) = {
            let mut state = self.inner.lock();
            let (posted, owner_events) = state.owner.post(item);
            (posted, Inner::local_events(&mut state, owner_events, now))
        };
        self.inner.emit(events);
        posted
    }

    /// `feed.withdraw`: the poster's open items with this key close.
    pub fn withdraw(&self, dedupe_key: &str) -> Vec<String> {
        let now = self.inner.now();
        let (ids, events) = {
            let mut state = self.inner.lock();
            let (ids, owner_events) = state.owner.withdraw(dedupe_key, now);
            (ids, Inner::local_events(&mut state, owner_events, now))
        };
        self.inner.emit(events);
        ids
    }

    // MARK: GitHub

    /// `feed.github.configure`.
    pub fn configure_github(&self, config: GitHubConfig) -> GitHubConfig {
        self.ensure_started();
        let (start, shown) = {
            let mut state = self.inner.lock();
            // The view shows `github.enabled`: a reader re-reads on a change of it.
            let shown = (state.github_config.enabled != config.enabled).then(|| FeedEvent::View {
                revision: state.mirror.revision(),
                changed: Vec::new(),
            });
            state.github_config = config;
            state.github_generation = state.github_generation.wrapping_add(1);
            state.github_epoch = state.github_epoch.wrapping_add(1);
            if !config.enabled {
                state.github_error = None;
            }
            (config.enabled && !state.github_running, shown)
        };
        self.inner.wake.notify_all();
        self.inner.emit(shown.into_iter().collect());
        if start {
            github::start(&self.inner);
        }
        config
    }

    /// `feed.github.refresh`: one user wakeup of the poller (its in-flight
    /// guard drops one that comes during a refresh). Answers whether the
    /// connection is on.
    pub fn refresh_github(&self) -> bool {
        let mut state = self.inner.lock();
        if !state.github_config.enabled {
            return false;
        }
        state.github_generation = state.github_generation.wrapping_add(1);
        drop(state);
        self.inner.wake.notify_all();
        true
    }

    /// `feed.github.find_work`: the user's review requests and assignments,
    /// read now (blocks on `gh`; run it off the request loop).
    pub fn find_work(&self) -> Result<Value, FeedError> {
        github::find_work(self.inner.deps.gh.as_ref()).map_err(FeedError::Unavailable)
    }

    // MARK: Presence and reports

    /// `feed.presence.set` from the verified frontend connection `client`:
    /// the app's active state for the owner's push rule. Active belongs to
    /// the connection that said it (``connection_closed`` takes it back); the
    /// owner hears active while any such connection holds it. An activation
    /// also wakes a reports reader past its retries.
    pub fn set_presence(&self, client: u64, active: bool) {
        self.ensure_started();
        let mut state = self.inner.lock();
        if active {
            state.presence_holders.insert(client);
        } else {
            state.presence_holders.remove(&client);
        }
        let effective = !state.presence_holders.is_empty();
        Self::send_presence(&mut state, effective);
        if active {
            state.reports_generation = state.reports_generation.wrapping_add(1);
        }
        drop(state);
        self.inner.wake.notify_all();
    }

    /// A connection closed (cleanly or not): the presence it held ends, and
    /// the owner hears inactive when no other frontend still holds it, so a
    /// crashed app never keeps suppressing the person's phone pushes.
    pub fn connection_closed(&self, client: u64) {
        let mut state = self.inner.lock();
        if !state.presence_holders.remove(&client) || !state.presence_holders.is_empty() {
            return;
        }
        Self::send_presence(&mut state, false);
        drop(state);
        self.inner.wake.notify_all();
    }

    /// Whether the owner hears the app as active (tests and diagnostics).
    pub fn presence(&self) -> bool {
        self.inner.lock().presence
    }

    fn send_presence(state: &mut State, active: bool) {
        state.presence = active;
        if let Some(frame) = state.stream.set_presence(active) {
            state.outbox.push(frame);
            Inner::wake_wire(state);
        }
    }

    /// `feed.reports.read`.
    pub fn reports(&self) -> Value {
        self.ensure_started();
        let state = self.inner.lock();
        json!({
            "revision": state.reports.revision(),
            "available": reports::person(&self.inner, state.account.as_deref()).is_some()
                && self.inner.deps.mailbox.available(),
            "reports": state.reports.list(),
        })
    }

    /// `feed.reports.reply` (blocks on acpmux; run it off the request loop).
    pub fn reply(&self, session: &str, text: &str, prompt_id: &str) -> bool {
        let sender = self.inner.reply.lock().unwrap_or_else(PoisonError::into_inner).clone();
        match sender {
            Some(sender) if !session.is_empty() && !prompt_id.is_empty() => {
                sender(session, text, prompt_id)
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests;
