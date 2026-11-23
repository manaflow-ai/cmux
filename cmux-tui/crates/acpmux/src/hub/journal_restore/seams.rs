//! Debug builds' seams of a journal restore (`journal_restore.rs`): a pause while it holds a
//! chat, a flush that fails, and the records each request carried.

use std::time::Duration;

/// Debug builds only: the restore of chat `id` waits `ms` once it holds the chat, so a test can
/// send a prompt in that window ([`test_paused`] says when it is in it).
#[cfg(debug_assertions)]
static PAUSE: std::sync::Mutex<Option<(String, u64, bool)>> = std::sync::Mutex::new(None);

#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn pause_once_holding(id: &str, ms: u64) {
    *PAUSE.lock().unwrap_or_else(|e| e.into_inner()) = Some((id.to_owned(), ms, false));
}

#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn test_paused() -> bool {
    PAUSE.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|p| p.2)
}

#[cfg(debug_assertions)]
pub(super) async fn test_pause(id: &str) {
    let ms = {
        let mut pause = PAUSE.lock().unwrap_or_else(|e| e.into_inner());
        match pause.as_mut() {
            Some(p) if p.0 == id && !p.2 => {
                p.2 = true;
                p.1
            }
            _ => return,
        }
    };
    tokio::time::sleep(Duration::from_millis(ms)).await;
    *PAUSE.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

/// Debug builds only: the next flush of a restore of chat `id` fails (a disk whose fsync fails),
/// after every record is written.
#[cfg(debug_assertions)]
static FLUSH_FAILS: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

#[cfg(debug_assertions)]
#[doc(hidden)]
pub fn fail_flush_once(id: &str) {
    *FLUSH_FAILS.lock().unwrap_or_else(|e| e.into_inner()) = Some(id.to_owned());
}

#[cfg(debug_assertions)]
pub(super) fn test_flush_fails(id: &str) -> bool {
    let mut armed = FLUSH_FAILS.lock().unwrap_or_else(|e| e.into_inner());
    let fails = armed.as_deref() == Some(id);
    if fails {
        *armed = None;
    }
    fails
}

#[cfg(not(debug_assertions))]
pub(super) fn test_flush_fails(_: &str) -> bool {
    false
}

/// The records every restore request of a chat carried, by chat: a fault test counts what a
/// restore cut midway sends again (`tests/machine_move_journey.rs`).
#[cfg(any(debug_assertions, test))]
static TAKEN: std::sync::Mutex<Vec<(String, usize)>> = std::sync::Mutex::new(Vec::new());

/// The records every restore request of chat `id` carried so far, summed.
#[cfg(any(debug_assertions, test))]
#[doc(hidden)]
pub fn records_taken(id: &str) -> usize {
    let taken = TAKEN.lock().unwrap_or_else(|e| e.into_inner());
    taken.iter().filter(|(chat, _)| chat == id).map(|(_, n)| n).sum()
}

#[cfg(any(debug_assertions, test))]
pub(super) fn note_taken(id: &str, records: usize) {
    TAKEN.lock().unwrap_or_else(|e| e.into_inner()).push((id.to_owned(), records));
}
