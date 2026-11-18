//! Auto chat placement's rejudge task (design/auto-chat-placement.md, "Moving a running chat").
//!
//! Leo, 2026-11-18: "esp with our auto routing logic. say like... an auto mode as an umbrella over
//! remote/local/cloud itself. so it just goes."
//!
//! On every change of the app's sleep word, every peer link change and every [`PASS_EVERY`], it
//! weighs each live chat tagged `placement=auto` (the app's `chat.placement` host call) with
//! `chat_place::rejudge`, keeping how long this Mac has been over load or low on battery
//! ([`Rejudger`]). A move to Cloud, or back from Cloud, goes to the app as `chatPlace/move` (its
//! existing Move to Cloud / Bring Back); a move to or back from a joined machine the daemon runs
//! itself, as `acpmux session move --host PEER` (and `--from PEER --host local`), the command
//! line's own path (`cli/run/session_move.rs`), which has no server-side twin.
//!
//! It runs only on macOS: Auto weighs "This Mac", and a chat Auto moved to a Linux machine must
//! not be judged again there as if it started there.

use super::Hub;
use crate::chat_place::{self, Input, Move, Needs, Place, Running};
use crate::hub::chat_place_bus::{AutoChat, parse_moved_tag};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

/// How often the task weighs the chats with nothing else waking it (this Mac's own health has no
/// change feed).
pub(super) const PASS_EVERY: Duration = Duration::from_secs(30);
/// A peer link change wakes a pass at most this often; the next tick takes the rest.
const PEER_WAKE_GAP: Duration = Duration::from_secs(5);
/// A chat Auto asked to move is not asked again for this long (an app that refused it, a move
/// that failed), unless the app said the Mac is going to sleep since.
pub(super) const RETRY_MS: u64 = 5 * 60 * 1000;
/// The longest the daemon's own peer move runs before it is stopped.
const PEER_MOVE_BOUND: Duration = Duration::from_secs(15 * 60);

/// One chat as the rejudge weighs it.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Chat {
    pub session: String,
    pub running: Running,
    /// Its id on the joined machine it moved to (`moved_to.sessionId`).
    pub there: Option<String>,
    /// What its work needs ([`NEEDS_TAG`](crate::hub::chat_place_bus::NEEDS_TAG), else [`folder_needs`]): `rejudge` weighs it per chat.
    pub needs: Needs,
}

impl Chat {
    /// From the hub's row: here while it has not moved; away where Auto's tag says it went; a chat
    /// that moved with no such tag was moved by the person, and Auto leaves it alone (pinned).
    /// `remote_turn(peer, id)` says whether a joined machine's row of it runs a turn.
    pub(super) fn of(c: &AutoChat, needs: Needs, remote_turn: impl Fn(&str, &str) -> bool) -> Self {
        let there = c
            .moved_to
            .as_ref()
            .and_then(|m| m.get("sessionId"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned);
        let (place, pinned) = match (&c.moved_to, c.moved_tag.as_deref().and_then(parse_moved_tag))
        {
            (None, _) => (Place::Local, false),
            (Some(_), Some(place)) => (place, false),
            (Some(_), None) => (Place::Local, true),
        };
        let turn_active = match (&place, &there) {
            (Place::Local, _) => c.turn_active,
            (Place::Peer(peer), Some(id)) => remote_turn(peer, id),
            _ => false,
        };
        Chat {
            session: c.session.clone(),
            running: Running { place, home: Place::Local, pinned, turn_active, local_over_secs: 0 },
            there,
            needs,
        }
    }
}

/// [`NEEDS_TAG`](crate::hub::chat_place_bus::NEEDS_TAG)'s value (`macos,gpu,build`) as needs; unknown words are ignored.
pub(super) fn tag_needs(tag: &str) -> Needs {
    let mut needs = Needs::default();
    for word in tag.split(',').map(str::trim) {
        match word {
            "macos" => needs.macos = true,
            "gpu" => needs.gpu = true,
            "build" | "longBuild" => needs.long_build = true,
            _ => {}
        }
    }
    needs
}

/// What a folder says the work needs, for a chat the app tagged with no needs: `macos` when it
/// holds an Xcode project or workspace, or a `Package.swift` that names an Apple platform. Reads
/// only the folder's own entries and at most [`PACKAGE_READ_BYTES`] of the manifest.
pub(super) fn folder_needs(cwd: &Path) -> Needs {
    let apple_project = std::fs::read_dir(cwd).into_iter().flatten().flatten().any(|e| {
        let name = e.file_name();
        let name = name.to_string_lossy();
        name.ends_with(".xcodeproj") || name.ends_with(".xcworkspace")
    });
    let apple_package = || {
        use std::io::Read as _;
        let Ok(file) = std::fs::File::open(cwd.join("Package.swift")) else { return false };
        let mut text = String::new();
        let _ = file.take(PACKAGE_READ_BYTES).read_to_string(&mut text);
        [".macOS(", ".iOS(", ".tvOS(", ".watchOS(", ".visionOS(", ".macCatalyst("]
            .iter()
            .any(|p| text.contains(p))
    };
    Needs { macos: apple_project || apple_package(), ..Needs::default() }
}

/// The most of a `Package.swift` [`folder_needs`] reads.
const PACKAGE_READ_BYTES: u64 = 64 * 1024;

/// What the task does for one move.
#[derive(Debug, Clone, PartialEq)]
pub(super) enum Order {
    /// Asks the app's mover: `chatPlace/move`.
    App { session: String, mv: Move },
    /// The daemon runs `acpmux --json ARGS` (`session move`).
    Run { session: String, mv: Move, args: Vec<String> },
}

impl Order {
    fn of(chat: &Chat, mv: Move) -> Option<Self> {
        let session = chat.session.clone();
        let args = |a: &[&str]| a.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        match (&mv.to, &chat.running.place) {
            (Place::Peer(peer), _) => {
                let args = args(&["session", "move", &session, "--host", peer]);
                Some(Order::Run { session, mv, args })
            }
            (Place::Local, Place::Peer(peer)) => {
                let there = chat.there.as_deref()?;
                let args = args(&["session", "move", there, "--from", peer, "--host", "local"]);
                Some(Order::Run { session, mv, args })
            }
            _ => Some(Order::App { session, mv }),
        }
    }
}

/// The rejudge's memory between passes: since when this Mac is over load or low on battery, and
/// when each chat was last asked to move.
#[derive(Debug, Default)]
pub(super) struct Rejudger {
    over_since_ms: Option<u64>,
    asked: HashMap<String, u64>,
    /// What each untagged chat's folder says it needs (`chat_needs`).
    folders: HashMap<PathBuf, Needs>,
}

impl Rejudger {
    /// No Auto chat: nothing to keep. A chat that comes later waits the whole hold.
    pub(super) fn idle(&mut self) {
        self.over_since_ms = None;
        self.asked.clear();
    }

    /// One pass at `now_ms`: the moves to make for `chats`, given `input` (this Mac and the
    /// joined machines now) and the chats already `moving`. `slept` says the app's sleep word
    /// changed since the last pass: a chat here is asked again even inside [`RETRY_MS`].
    pub(super) fn step(
        &mut self,
        now_ms: u64,
        chats: &[Chat],
        input: &mut Input,
        moving: &[String],
        slept: bool,
    ) -> Vec<Order> {
        // This Mac is over for one plain lane of work; each chat is then weighed with its own needs.
        input.needs = Needs::default();
        if chat_place::local_over(input) {
            self.over_since_ms.get_or_insert(now_ms);
        } else {
            self.over_since_ms = None;
        }
        let local_over_secs = self.over_since_ms.map_or(0, |at| now_ms.saturating_sub(at) / 1000);
        self.asked.retain(|_, at| now_ms.saturating_sub(*at) < RETRY_MS);
        let mut orders = Vec::new();
        for chat in chats {
            if moving.contains(&chat.session) {
                continue;
            }
            let urgent = slept && chat.running.place == Place::Local && input.power.away();
            if self.asked.contains_key(&chat.session) && !urgent {
                continue;
            }
            let running = Running { local_over_secs, ..chat.running.clone() };
            input.needs = chat.needs.clone();
            let Some(order) = chat_place::rejudge(&running, input).and_then(|m| Order::of(chat, m))
            else {
                continue;
            };
            self.asked.insert(chat.session.clone(), now_ms);
            orders.push(order);
        }
        orders
    }
}

/// Starts the task once per daemon (macOS only).
pub(super) fn start(hub: &Arc<Hub>) {
    if !cfg!(target_os = "macos") || !hub.chat_place.start_once() {
        return;
    }
    let weak = Arc::downgrade(hub);
    let mut sleep = hub.chat_place.sleep_changes();
    let mut links = hub.peer_states().subscribe();
    hub.scope.spawn_until_cancelled("chat-place-rejudge", async move {
        let mut judge = Rejudger::default();
        let mut tick = tokio::time::interval(PASS_EVERY);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut seen = 0;
        loop {
            let generation = sleep.borrow_and_update().generation;
            {
                let Some(hub) = weak.upgrade() else { return };
                pass(&hub, &mut judge, generation != seen).await;
                hub.chat_place.rejudged(generation);
            }
            seen = generation;
            let last = tokio::time::Instant::now();
            loop {
                tokio::select! {
                    changed = sleep.changed() => {
                        if changed.is_err() { return; }
                        break;
                    }
                    note = links.recv() => {
                        if matches!(note, Err(tokio::sync::broadcast::error::RecvError::Closed)) {
                            return;
                        }
                        if last.elapsed() >= PEER_WAKE_GAP { break; }
                    }
                    _ = tick.tick() => break,
                }
            }
        }
    });
}

/// One pass over the live Auto chats.
async fn pass(hub: &Arc<Hub>, judge: &mut Rejudger, slept: bool) {
    let rows = hub.auto_chats();
    if rows.is_empty() {
        judge.idle();
        return;
    }
    let moving = hub.chat_place.in_flight();
    // A chat back here (or one whose move stayed) forgets where Auto had moved it.
    for row in rows.iter().filter(|r| r.moved_to.is_none() && r.moved_tag.is_some()) {
        if !moving.contains(&row.session) {
            hub.clear_auto_move(&row.session);
        }
    }
    let needs = chat_needs(&rows, &mut judge.folders).await;
    let chats: Vec<Chat> = rows
        .iter()
        .zip(needs)
        .map(|(r, needs)| Chat::of(r, needs, |peer, id| hub.remote_turn_active(peer, id)))
        .collect();
    let mut input = super::place::auto_input(
        hub,
        chat_place::Folder::default(),
        chat_place::Needs::default(),
        hub.chat_place.cloud(),
    )
    .await;
    for order in judge.step(crate::store::now_ms(), &chats, &mut input, &moving, slept) {
        match order {
            Order::App { session, mv } => {
                tracing::info!(session = %session, to = mv.to.kind(), why = %mv.why, "chat place: asking the app to move");
                hub.note_auto_move(&session, &mv.to);
                hub.chat_place.emit(&session, &mv);
            }
            Order::Run { session, mv, args } => {
                tracing::info!(session = %session, to = mv.to.kind(), why = %mv.why, "chat place: moving");
                hub.note_auto_move(&session, &mv.to);
                hub.chat_place.begin(&session, PEER_MOVE_BOUND);
                let owner = hub.clone();
                hub.scope.spawn_until_cancelled("chat-place-move", async move {
                    run_move(&args).await;
                    owner.chat_place.end(&session);
                });
            }
        }
    }
}

/// Each row's needs: its [`NEEDS_TAG`](crate::hub::chat_place_bus::NEEDS_TAG), else what its folder says ([`folder_needs`], read off the
/// runtime once per folder and kept in `folders`, which keeps only the folders of `rows`).
async fn chat_needs(rows: &[AutoChat], folders: &mut HashMap<PathBuf, Needs>) -> Vec<Needs> {
    let untagged: Vec<PathBuf> =
        rows.iter().filter(|r| r.needs_tag.is_none()).map(|r| r.cwd.clone()).collect();
    folders.retain(|cwd, _| untagged.contains(cwd));
    let unread: Vec<PathBuf> = untagged.into_iter().filter(|c| !folders.contains_key(c)).collect();
    if !unread.is_empty() {
        let read = tokio::task::spawn_blocking(move || {
            unread.into_iter().map(|c| (folder_needs(&c), c)).collect::<Vec<_>>()
        })
        .await
        .unwrap_or_default();
        folders.extend(read.into_iter().map(|(n, c)| (c, n)));
    }
    rows.iter()
        .map(|r| match &r.needs_tag {
            Some(tag) => tag_needs(tag),
            None => folders.get(&r.cwd).cloned().unwrap_or_default(),
        })
        .collect()
}

/// `acpmux --json ARGS` from this daemon's own binary, bounded by [`PEER_MOVE_BOUND`].
async fn run_move(args: &[String]) {
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(e) => {
            tracing::warn!("chat place: no acpmux binary for the move: {e}");
            return;
        }
    };
    let mut cmd = tokio::process::Command::new(exe);
    cmd.args(crate::daemon::daemon_prefix())
        .arg("--json")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    match tokio::time::timeout(PEER_MOVE_BOUND, cmd.output()).await {
        Ok(Ok(out)) if out.status.success() => tracing::info!(?args, "chat place: moved"),
        Ok(Ok(out)) => tracing::warn!(
            ?args,
            status = %out.status,
            stderr = %String::from_utf8_lossy(&out.stderr).trim(),
            "chat place: the move failed"
        ),
        Ok(Err(e)) => tracing::warn!(?args, "chat place: the move did not start: {e}"),
        Err(_) => tracing::warn!(?args, "chat place: the move ran past its bound and was stopped"),
    }
}

#[cfg(test)]
#[path = "place_auto_tests.rs"]
mod tests;
