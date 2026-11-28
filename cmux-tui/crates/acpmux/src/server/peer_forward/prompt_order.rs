//! Prompts for one chat on a peer go out in the order they came, through a link cut too. Part of
//! `peer_forward.rs`.
//!
//! Before, each prompt held for a link that was down (`wait_for_prompt_link`) woke on its own when
//! the link came back. Two or more sent during one cut raced to the link, and the far chat could
//! run the later one first (review of cmux#53265: "two prompts to the same chat during one cut can
//! arrive out of order"). A game's netcode orders input the same way: the server applies
//! commands in the client's sequence, whatever order the packets land in.
//!
//! Each prompt for a peer's chat takes that chat's turn ([`turn`]): a fair (first in, first out)
//! lock, so the turns go in arrival order. It holds the turn through its wait for the link and
//! gives it up once its frame is on the link ([`until_on_wire`], told by
//! `peer::PROMPT_ON_WIRE`), not when the far turn ends, so a prompt on a link that is up waits
//! for nothing but the one ahead of it to be queued. A prompt that ends without going (refused,
//! queued in the outbox, cancelled) gives the turn up when it ends.

use super::*;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex as StdMutex, Weak};
use tokio::sync::{Mutex as TurnLock, OwnedMutexGuard};

/// A chat's turn, held by the prompt that goes next.
pub(super) type Turn = OwnedMutexGuard<()>;

/// Each chat's turn lock while a prompt holds or waits for it, by hub (its address: a test runs
/// many in one process), peer and chat. An entry whose lock nobody holds any more is dropped on
/// the next look-up.
type Key = (usize, String, String);
static TURNS: LazyLock<StdMutex<HashMap<Key, Weak<TurnLock<()>>>>> =
    LazyLock::new(Default::default);

/// Waits for chat `session` on peer `peer`'s turn, behind every prompt for it that came before.
pub(super) async fn turn(hub: &Arc<Hub>, peer: &str, session: &str) -> Turn {
    #[cfg(test)]
    if UNORDERED.with(std::cell::Cell::get) {
        return Arc::new(TurnLock::new(())).lock_owned().await;
    }
    let lock = {
        let mut turns = TURNS.lock_or_recover();
        turns.retain(|_, lock| lock.strong_count() > 0);
        let key = (Arc::as_ptr(hub) as usize, peer.to_owned(), session.to_owned());
        match turns.get(&key).and_then(Weak::upgrade) {
            Some(lock) => lock,
            None => {
                let lock = Arc::new(TurnLock::new(()));
                turns.insert(key, Arc::downgrade(&lock));
                lock
            }
        }
    };
    lock.lock_owned().await
}

/// Runs `send` (the prompt's forward) and gives up `turn` once its prompt is on the link, or when
/// `send` ends without that; `turn` stays held when `send` ends first, so a prompt that is held
/// again goes on in its place.
pub(super) async fn until_on_wire<F: std::future::Future>(
    turn: &mut Option<Turn>,
    send: F,
) -> F::Output {
    let on_wire = Arc::new(tokio::sync::Notify::new());
    let send = crate::peer::PROMPT_ON_WIRE.scope(on_wire.clone(), send);
    tokio::pin!(send);
    if turn.is_some() {
        tokio::select! {
            biased;
            out = &mut send => return out,
            () = on_wire.notified() => { turn.take(); }
        }
    }
    send.await
}

#[cfg(test)]
thread_local! {
    /// The order off on this thread, for a before/after number from one build.
    static UNORDERED: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Turns the per-chat order off (`true`) or back on for prompts sent from this thread (a paused
/// test's runtime runs every task on it), so one test binary measures before and after.
#[cfg(test)]
pub(super) fn unordered_for_tests(on: bool) {
    UNORDERED.with(|u| u.set(on));
}
