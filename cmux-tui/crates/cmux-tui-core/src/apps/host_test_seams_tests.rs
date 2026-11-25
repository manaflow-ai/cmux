use std::sync::{Mutex, PoisonError};
use std::time::Duration;

static PAUSES: Mutex<Vec<(String, Duration)>> = Mutex::new(Vec::new());

/// The next start of a host named `name` takes `pause` longer.
pub(in crate::apps) fn pause_next_spawn(name: &str, pause: Duration) {
    PAUSES.lock().unwrap_or_else(PoisonError::into_inner).push((name.into(), pause));
}

pub(super) fn spawn_pause(name: &str) {
    let pause = {
        let mut pauses = PAUSES.lock().unwrap_or_else(PoisonError::into_inner);
        let index = pauses.iter().position(|(n, _)| n == name);
        index.map(|i| pauses.remove(i).1)
    };
    if let Some(pause) = pause {
        std::thread::sleep(pause);
    }
}
