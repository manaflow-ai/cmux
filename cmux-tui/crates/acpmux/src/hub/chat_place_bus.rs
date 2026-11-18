//! Auto chat placement's state in the daemon (design/auto-chat-placement.md, "Moving a running
//! chat"): whether the app said this Mac is going to sleep (`power.sleeping`, which no health
//! reading sees in time), the moves the rejudge task (`server/place_auto.rs`) asks the app to run
//! (`chatPlace/move`), and which chats are moving now.
//!
//! The decision (`chat_place.rs`, `rejudge`) is not here: this only carries its inputs and
//! outputs. Every local-origin connection hears each `chatPlace/move` (`server/fanout.rs`); the
//! app's mover runs the existing Move to Cloud / Bring Back action for it. A move to or from a
//! joined machine never goes to the app: the daemon runs `acpmux session move` itself, and only
//! marks the chat moving here ([`ChatPlaceBus::begin`]). A move is in flight until this daemon's
//! log says the chat left (`transferred`), came back (`transferred_in`) or stayed
//! (`transfer_aborted`), the daemon's own peer move ended ([`ChatPlaceBus::end`]), or
//! [`IN_FLIGHT_BOUND`] passed (an app that refused the move writes nothing here). `willSleep` waits
//! for the rejudge to answer, then `_acpmux/place_chat_settled` waits for the moves in flight, so
//! the app holds sleep until the chats it was moving off this Mac have gone.

use super::*;
use crate::chat_place::{Cloud, Move, Place};
use std::time::Instant;
use tokio::sync::watch;

/// The notification the app's mover hears.
pub const MOVE_METHOD: &str = "chatPlace/move";
/// How long a move counts as in flight with no end in the log.
pub const IN_FLIGHT_BOUND: std::time::Duration = std::time::Duration::from_secs(120);
/// How long `willSleep` waits for the rejudge task to answer the power change.
pub const REJUDGE_BOUND: std::time::Duration = std::time::Duration::from_secs(3);
/// The tag the app's `chat.placement` host call sets on a chat Auto places: `placement=auto`.
pub const PLACEMENT_TAG: &str = "placement";
pub const PLACEMENT_AUTO: &str = "auto";
/// The tag that remembers where Auto moved a chat (`cloud`, `peer:NAME`), so a restarted daemon
/// still brings it back. A chat that moved away without it was moved by the person: Auto leaves it.
pub const MOVED_TAG: &str = "placementMoved";
/// The log records that end a move.
const ENDS: [&str; 3] = ["transferred", "transferred_in", "transfer_aborted"];
const MOVES_BUFFER: usize = 64;

/// The app's word on sleep.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Sleep {
    /// The app said the Mac is going to sleep (lid closed, idle or menu sleep), until it says it woke.
    pub sleeping: bool,
    /// Raised by every change; what [`ChatPlaceBus::rejudged`] answers.
    pub generation: u64,
}

pub struct ChatPlaceBus {
    sleep: watch::Sender<Sleep>,
    rejudged: watch::Sender<u64>,
    moves: broadcast::Sender<Value>,
    in_flight: StdMutex<HashMap<String, Instant>>,
    ended: Notify,
    /// The Cloud plan the app last passed in `_acpmux/place_chat`; unavailable until it does.
    cloud: StdMutex<Cloud>,
    /// The rejudge task started (it runs once per daemon).
    started: AtomicBool,
}

impl Default for ChatPlaceBus {
    fn default() -> Self {
        ChatPlaceBus {
            sleep: watch::channel(Sleep::default()).0,
            rejudged: watch::channel(0).0,
            moves: broadcast::channel(MOVES_BUFFER).0,
            in_flight: StdMutex::new(HashMap::new()),
            ended: Notify::new(),
            cloud: StdMutex::new(Cloud::default()),
            started: AtomicBool::new(false),
        }
    }
}

impl ChatPlaceBus {
    pub fn sleeping(&self) -> bool {
        self.sleep.borrow().sleeping
    }

    /// The sleep state as it changes: the rejudge task watches this and answers each change with
    /// [`Self::rejudged`].
    pub fn sleep_changes(&self) -> watch::Receiver<Sleep> {
        self.sleep.subscribe()
    }

    /// Records the app's sleep or wake; returns the generation after it.
    pub fn set_sleeping(&self, sleeping: bool) -> u64 {
        let mut generation = 0;
        self.sleep.send_if_modified(|s| {
            let changed = s.sleeping != sleeping;
            if changed {
                s.sleeping = sleeping;
                s.generation += 1;
            }
            generation = s.generation;
            changed
        });
        generation
    }

    /// The rejudge answered the change of `generation` (emitted its moves for it).
    pub fn rejudged(&self, generation: u64) {
        self.rejudged.send_if_modified(|seen| {
            let raised = generation > *seen;
            if raised {
                *seen = generation;
            }
            raised
        });
    }

    /// Waits, at most `bound`, until the rejudge answered `generation`. Returns at once when no
    /// rejudge task watches the sleep state.
    pub async fn wait_rejudged(&self, generation: u64, bound: std::time::Duration) {
        if self.sleep.receiver_count() == 0 {
            return;
        }
        let mut seen = self.rejudged.subscribe();
        let _ = tokio::time::timeout(bound, seen.wait_for(|seen| *seen >= generation)).await;
    }

    /// The Cloud plan the app passed last.
    pub fn cloud(&self) -> Cloud {
        self.cloud.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn set_cloud(&self, cloud: Cloud) {
        *self.cloud.lock().unwrap_or_else(|e| e.into_inner()) = cloud;
    }

    /// True the first time only: the rejudge task starts once.
    pub fn start_once(&self) -> bool {
        !self.started.swap(true, Ordering::SeqCst)
    }

    /// `session` is moving from now on, for at most `bound` (an app move: [`IN_FLIGHT_BOUND`]; the
    /// daemon's own peer move: its command's bound, ended by [`Self::end`]).
    pub fn begin(&self, session: &str, bound: std::time::Duration) {
        self.lock().insert(session.to_owned(), Instant::now() + bound);
    }

    /// The daemon's own move of `session` ended, whatever its outcome.
    pub fn end(&self, session: &str) {
        if self.lock().remove(session).is_some() {
            self.ended.notify_waiters();
        }
    }

    /// Asks the app's mover to run `mv` for `session` (`chatPlace/move {session, to, peer, why,
    /// back}`); it is in flight until it ends.
    pub fn emit(&self, session: &str, mv: &Move) {
        self.begin(session, IN_FLIGHT_BOUND);
        let _ = self.moves.send(move_params(session, mv));
    }

    /// Every move emitted from now on, as `chatPlace/move` params.
    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.moves.subscribe()
    }

    /// A log record of `session`: a move's end takes it out of flight.
    pub fn record(&self, session: &str, dir: &str, kind: &str) {
        if dir == "mux" && ENDS.contains(&kind) {
            self.end(session);
        }
    }

    /// The sessions with a move in flight now, sorted.
    pub fn in_flight(&self) -> Vec<String> {
        let mut map = self.lock();
        let now = Instant::now();
        map.retain(|_, until| *until > now);
        let mut sessions: Vec<_> = map.keys().cloned().collect();
        sessions.sort();
        sessions
    }

    /// Waits, at most `bound`, until no move is in flight; returns the ones still moving.
    pub async fn settled(&self, bound: std::time::Duration) -> Vec<String> {
        let deadline = tokio::time::Instant::now() + bound;
        loop {
            let ended = self.ended.notified();
            tokio::pin!(ended);
            ended.as_mut().enable();
            let left = self.in_flight();
            if left.is_empty() || tokio::time::Instant::now() >= deadline {
                return left;
            }
            // The next end, or a second (a move's bound may pass meanwhile), or the deadline.
            let tick =
                deadline.min(tokio::time::Instant::now() + std::time::Duration::from_secs(1));
            let _ = tokio::time::timeout_at(tick, ended).await;
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Instant>> {
        self.in_flight.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

/// `chatPlace/move`'s params.
pub fn move_params(session: &str, mv: &Move) -> Value {
    let mut v = mv.to_json();
    if let Some(o) = v.as_object_mut() {
        o.insert("session".into(), json!(session));
    }
    v
}

/// [`MOVED_TAG`]'s value for a place, and back.
pub fn moved_tag(place: &Place) -> Option<String> {
    match place {
        Place::Local => None,
        Place::Cloud => Some("cloud".into()),
        Place::Peer(p) => Some(format!("peer:{p}")),
    }
}

pub fn parse_moved_tag(tag: &str) -> Option<Place> {
    match tag {
        "cloud" => Some(Place::Cloud),
        _ => tag.strip_prefix("peer:").filter(|p| !p.is_empty()).map(|p| Place::Peer(p.into())),
    }
}

/// A live chat on this daemon tagged `placement=auto`, as the rejudge task reads it.
#[derive(Debug, Clone, PartialEq)]
pub struct AutoChat {
    pub session: String,
    /// Its turn runs here (running, or waiting on a permission).
    pub turn_active: bool,
    /// Where it went when it moved (`SessionMeta::moved_to`).
    pub moved_to: Option<Value>,
    /// [`MOVED_TAG`], when Auto moved it.
    pub moved_tag: Option<String>,
}

impl Hub {
    /// The live chats here tagged `placement=auto`.
    pub(crate) fn auto_chats(&self) -> Vec<AutoChat> {
        let now = now_ms();
        let live = |t: &crate::store::Tag| t.expires_at.is_none_or(|e| e > now);
        self.live_session_handles()
            .into_iter()
            .filter_map(|s| {
                s.read_meta(|m| {
                    let tag = |k: &str| m.tags.get(k).filter(|t| live(t)).map(|t| t.value.clone());
                    (tag(PLACEMENT_TAG).as_deref() == Some(PLACEMENT_AUTO)).then(|| AutoChat {
                        session: m.id.clone(),
                        turn_active: matches!(
                            m.status,
                            SessionStatus::Running | SessionStatus::Waiting
                        ),
                        moved_to: m.moved_to.clone(),
                        moved_tag: tag(MOVED_TAG),
                    })
                })
            })
            .collect()
    }

    /// Whether `peer`'s row of its chat `id` says a turn runs (no row: no).
    pub(crate) fn remote_turn_active(&self, peer: &str, id: &str) -> bool {
        let rows = self.remote_sessions.snapshot();
        rows.values().any(|r| {
            r.peer == peer
                && r.summary.session_id() == Some(id)
                && matches!(r.summary.status(), Some("running" | "waiting"))
        })
    }

    /// Remembers on the chat where Auto moves it ([`MOVED_TAG`]), before the move starts.
    pub(crate) fn note_auto_move(&self, session: &str, place: &Place) {
        let Some(value) = moved_tag(place) else { return };
        let Ok(s) = self.resolve(session) else { return };
        let mut set = serde_json::Map::new();
        set.insert(MOVED_TAG.into(), json!(value));
        self.set_tags(&s, Some(&set), &[], None);
    }

    /// Forgets where Auto moved a chat that is here again (or whose move stayed).
    pub(crate) fn clear_auto_move(&self, session: &str) {
        let Ok(s) = self.resolve(session) else { return };
        self.set_tags(&s, None, &[MOVED_TAG.to_owned()], None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mv(to: Place) -> Move {
        Move { to, why: "sleep".into(), back: false }
    }

    #[test]
    fn chat_place_sleep_raises_the_generation_once_per_change() {
        let bus = ChatPlaceBus::default();
        assert!(!bus.sleeping());
        assert_eq!(bus.set_sleeping(true), 1);
        assert_eq!(bus.set_sleeping(true), 1);
        assert!(bus.sleeping());
        assert_eq!(bus.set_sleeping(false), 2);
        assert!(!bus.sleeping());
    }

    #[test]
    fn chat_place_move_is_sent_as_its_wire_params() {
        let bus = ChatPlaceBus::default();
        let mut rx = bus.subscribe();
        bus.emit("s1", &Move { to: Place::Local, why: "This Mac is back".into(), back: true });
        assert_eq!(
            rx.try_recv().unwrap(),
            json!({"session": "s1", "to": "local", "peer": null, "why": "This Mac is back",
                "back": true})
        );
        bus.emit("s2", &mv(Place::Cloud));
        assert_eq!(rx.try_recv().unwrap()["to"], "cloud");
        assert_eq!(bus.in_flight(), ["s1", "s2"]);
    }

    #[test]
    fn chat_place_move_ends_on_its_transfer_record_only() {
        let bus = ChatPlaceBus::default();
        bus.emit("s1", &mv(Place::Cloud));
        bus.emit("s2", &mv(Place::Local));
        bus.record("s1", "agent", "transferred");
        bus.record("s1", "mux", "prompt");
        assert_eq!(bus.in_flight(), ["s1", "s2"]);
        bus.record("s1", "mux", "transferred");
        bus.record("s2", "mux", "transferred_in");
        assert!(bus.in_flight().is_empty());
        bus.emit("s3", &mv(Place::Cloud));
        bus.record("s3", "mux", "transfer_aborted");
        assert!(bus.in_flight().is_empty());
        // The daemon's own peer move ends when its command does.
        bus.begin("s4", std::time::Duration::from_secs(900));
        assert_eq!(bus.in_flight(), ["s4"]);
        bus.end("s4");
        assert!(bus.in_flight().is_empty());
    }

    #[test]
    fn chat_place_moved_tag_round_trips() {
        for place in [Place::Cloud, Place::Peer("huge-blue".into())] {
            assert_eq!(parse_moved_tag(&moved_tag(&place).unwrap()), Some(place));
        }
        assert_eq!(moved_tag(&Place::Local), None);
        assert_eq!(parse_moved_tag("peer:"), None);
        assert_eq!(parse_moved_tag("mars"), None);
    }

    #[tokio::test]
    async fn chat_place_settled_returns_when_the_last_move_ends() {
        let bus = Arc::new(ChatPlaceBus::default());
        bus.emit("s1", &mv(Place::Cloud));
        let ender = bus.clone();
        let end = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(50)).await;
            ender.record("s1", "mux", "transferred");
        });
        let started = Instant::now();
        assert!(bus.settled(std::time::Duration::from_secs(10)).await.is_empty());
        assert!(started.elapsed() < std::time::Duration::from_secs(5));
        end.await.unwrap();
    }

    #[tokio::test]
    async fn chat_place_settled_gives_up_at_its_bound() {
        let bus = ChatPlaceBus::default();
        bus.emit("s1", &mv(Place::Cloud));
        assert_eq!(bus.settled(std::time::Duration::from_millis(100)).await, ["s1"]);
    }

    #[tokio::test]
    async fn chat_place_wait_rejudged_waits_only_for_a_watching_task() {
        let bus = Arc::new(ChatPlaceBus::default());
        let generation = bus.set_sleeping(true);
        // No rejudge task: no wait.
        let started = Instant::now();
        bus.wait_rejudged(generation, std::time::Duration::from_secs(10)).await;
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
        // A rejudge task answers the change.
        let mut changes = bus.sleep_changes();
        let task = bus.clone();
        let answer = tokio::spawn(async move {
            let sleep = *changes.borrow_and_update();
            task.emit("s1", &mv(Place::Cloud));
            task.rejudged(sleep.generation);
            let _ = changes.changed().await;
        });
        bus.wait_rejudged(generation, std::time::Duration::from_secs(10)).await;
        assert_eq!(bus.in_flight(), ["s1"]);
        bus.set_sleeping(false);
        answer.await.unwrap();
    }

    #[test]
    fn chat_place_cloud_is_unavailable_until_the_app_says() {
        let bus = ChatPlaceBus::default();
        assert!(!bus.cloud().available);
        bus.set_cloud(Cloud { available: true, ..Cloud::default() });
        assert!(bus.cloud().available);
        assert!(bus.start_once());
        assert!(!bus.start_once());
    }
}
