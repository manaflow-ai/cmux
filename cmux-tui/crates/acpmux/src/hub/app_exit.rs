//! A watched Claude Code chat whose app process exited reads `disconnected` (RFD 0049 R5).
//!
//! A chat the desktop bridge lists or `acpmux register` names shows a conversation another
//! process runs: acpmux did not start it, so no harness exit tells the hub it ended. Before this,
//! nothing did: a killed Claude Code left its registry entry and its chat at its last status, and
//! `acpmux ls` read it alive for good (the duress bench's external row, past its 90 s window).
//!
//! Each such chat follows the Claude Code processes its registry entries name ([`Hub::follow_app`]):
//! their pid and start time, armed on the one process exit watcher (`proc_exit.rs`), so the chat
//! hears the kernel's exit event, with no polling and no thread of its own. Once none of them runs,
//! the chat's row reads `disconnected` until a live process for its conversation is listed again
//! (the bridge's scan of a new entry, or `register --renew`). Only an exit does it: a stopped or
//! starved app has not exited and stays as it was. The state is the daemon's memory of the kernel's
//! word, never written to the store: a restarted daemon reads it again from the registry.
//!
//! A chat is followed only when the registry names its process: the bridge's listing and
//! `register` pass the pid, and a chat restored from the store has the `origin.pid` tag they set.
//! A watched chat nothing bridged (an `acpmux adopt` of a transcript) is not followed.

use super::{Hub, Session};
use crate::store::SessionStatus;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, LazyLock, Mutex, Weak};

/// The processes a chat follows: pid and start time.
type Proc = (u32, Option<u64>);

#[derive(Default)]
struct Followed {
    /// The live processes running the chat's conversation, each armed on the exit watcher.
    procs: HashSet<Proc>,
    /// None of them runs any more.
    gone: bool,
}

/// Followed chats by id.
static FOLLOWED: LazyLock<Mutex<HashMap<String, Followed>>> = LazyLock::new(Default::default);

fn followed() -> std::sync::MutexGuard<'static, HashMap<String, Followed>> {
    FOLLOWED.lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether chat `id`'s app exited: every process that ran its conversation is gone.
pub(super) fn gone(id: &str) -> bool {
    followed().get(id).is_some_and(|f| f.gone)
}

/// The status a watched chat's row reads: `disconnected` once its app exited, else `status`.
pub(super) fn row_status(session: &Session, status: SessionStatus) -> String {
    if status != SessionStatus::Closed && gone(&session.id) {
        SessionStatus::Disconnected.to_string()
    } else {
        status.to_string()
    }
}

impl Hub {
    /// Follows the Claude Code process that runs `session`'s watched conversation: `pid` when the
    /// caller read it from the registry, else the `origin.pid` tag a listing set. Reads the
    /// registry entry off the runtime, then arms the exit watch for a process not yet followed.
    pub(super) fn follow_app(self: &Arc<Self>, session: &Arc<Session>, pid: Option<u32>) {
        let m = session.meta();
        if m.watching.as_ref().is_none_or(|w| w.family != "claude") {
            return;
        }
        let Some(conversation) = m.agent_session_id.clone() else { return };
        let tagged = m
            .tags
            .get("bridge")
            .filter(|t| t.value == "claude")
            .and_then(|_| m.tags.get("origin.pid"))
            .and_then(|t| t.value.parse::<u32>().ok());
        let Some(pid) = pid.or(tagged) else { return };
        let config = self.harness_homes().claude;
        let (hub, chat) = (Arc::downgrade(self), session.id.clone());
        let runtime = tokio::runtime::Handle::current();
        drop(tokio::task::spawn_blocking(move || {
            // The entry's process, proven the one that wrote it; its start read after that proof.
            let live = crate::claude_peers::entry(&config, pid)
                .filter(|p| p.session_id == conversation)
                .and_then(|p| Some((p.pid, Some(crate::owner_exit::process_start(p.pid)?))));
            tracing::debug!(chat, pid, live = ?live, "following the watched app");
            seen(&hub, &chat, live, &runtime);
        }));
    }
}

/// Records what the registry said of `chat`'s process: `live` is armed when new; with none live
/// and none followed, the chat's app is gone (a restored chat whose app exited while the daemon
/// was down).
fn seen(hub: &Weak<Hub>, chat: &str, live: Option<Proc>, runtime: &tokio::runtime::Handle) {
    let (arm, changed) = {
        let mut map = followed();
        let f = map.entry(chat.to_owned()).or_default();
        let arm = live.filter(|p| f.procs.insert(*p));
        let gone = f.procs.is_empty();
        let changed = f.gone != gone;
        f.gone = gone;
        (arm, changed)
    };
    if changed {
        tell(hub, chat, runtime);
    }
    let Some((pid, start)) = arm else { return };
    let on_exit = {
        let (hub, chat, runtime) = (hub.clone(), chat.to_owned(), runtime.clone());
        move || exited(&hub, &chat, (pid, start), &runtime)
    };
    if let Err(error) = crate::proc_exit::watch(pid, start, on_exit) {
        // No exit event on this host: the chat is not followed, as before.
        tracing::warn!(chat, pid, %error, "cannot watch the app's exit");
        if let Some(f) = followed().get_mut(chat) {
            f.procs.remove(&(pid, start));
        }
    }
}

/// The exit watcher heard `proc` exit (on its thread: nothing here blocks).
fn exited(hub: &Weak<Hub>, chat: &str, proc: Proc, runtime: &tokio::runtime::Handle) {
    let now_gone = {
        let mut map = followed();
        let Some(f) = map.get_mut(chat) else { return };
        f.procs.remove(&proc);
        let now_gone = f.procs.is_empty() && !f.gone;
        f.gone |= now_gone;
        now_gone
    };
    if now_gone {
        tracing::info!(chat, pid = proc.0, "the watched app exited");
        tell(hub, chat, runtime);
    }
}

/// `chat`'s row changed: its cached bytes go stale and the list hears of it. A chat that is gone
/// is forgotten.
fn tell(hub: &Weak<Hub>, chat: &str, runtime: &tokio::runtime::Handle) {
    let (hub, chat) = (hub.clone(), chat.to_owned());
    drop(runtime.spawn(async move {
        let session = hub.upgrade().and_then(|hub| Some((hub.session_by_id(&chat)?, hub)));
        match session {
            Some((session, hub)) => hub.events.row_changed(&session),
            None => drop(followed().remove(&chat)),
        }
    }));
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
#[path = "app_exit_tests.rs"]
mod tests;
