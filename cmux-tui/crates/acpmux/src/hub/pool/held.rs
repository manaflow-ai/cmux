//! An entry's wire log and inbound traffic, held in memory until a session
//! takes the entry: an untaken pooled session writes nothing anywhere.

use super::super::*;
use crate::agent::Tap;
use std::collections::VecDeque;

/// Held log lines and inbound messages per entry, beyond which stderr is
/// dropped (anything else is kept).
const HELD_CAP: usize = 1024;

/// Log lines (with their host entry) held until a session takes the entry.
pub(super) enum TapSlot {
    Held(Vec<(Direction, Message, Option<u64>)>),
    Live(Tap),
}

fn is_stderr_note(msg: &Message) -> bool {
    matches!(msg, Message::Notification { method, .. } if method == crate::agent::HOST_STDERR)
}

/// A tap that holds every line until the entry is taken. Held lines count
/// as stored: they reach the session log, in order, when it is taken.
pub(super) fn holding_tap() -> (Tap, Arc<StdMutex<TapSlot>>) {
    let slot = Arc::new(StdMutex::new(TapSlot::Held(Vec::new())));
    let s = slot.clone();
    let tap: Tap = Arc::new(move |dir, msg, host_seq| {
        let mut guard = s.lock().unwrap();
        match &mut *guard {
            TapSlot::Held(held) => {
                if held.len() < HELD_CAP || !is_stderr_note(msg) {
                    held.push((dir, msg.clone(), host_seq));
                }
                true
            }
            TapSlot::Live(live) => {
                let live = live.clone();
                drop(guard);
                live(dir, msg, host_seq)
            }
        }
    });
    (tap, slot)
}

/// Inbound traffic of an entry: held until a session's channel arrives,
/// then forwarded in order.
pub(super) fn holding_inbound() -> (mpsc::Sender<Inbound>, oneshot::Sender<mpsc::Sender<Inbound>>) {
    let (tx, mut rx) = mpsc::channel::<Inbound>(1024);
    let (target_tx, mut target_rx) = oneshot::channel::<mpsc::Sender<Inbound>>();
    tokio::spawn(async move {
        let mut held = VecDeque::new();
        let target = loop {
            tokio::select! {
                t = &mut target_rx => match t {
                    Ok(t) => break t,
                    Err(_) => return, // ended untaken
                },
                m = rx.recv() => match m {
                    Some(m) => {
                        if held.len() < HELD_CAP || !matches!(m, Inbound::Stderr(..)) {
                            held.push_back(m);
                        }
                    }
                    None => return,
                },
            }
        };
        for m in held {
            if target.send(m).await.is_err() {
                return;
            }
        }
        while let Some(m) = rx.recv().await {
            if target.send(m).await.is_err() {
                return;
            }
        }
    });
    (tx, target_tx)
}
