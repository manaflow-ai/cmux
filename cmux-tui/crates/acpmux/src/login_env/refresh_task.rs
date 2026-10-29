//! One read of the login environment after the startup files changed (`refresh`). It
//! owns only the refresh's own state (`REFRESHING`, the fingerprint): a panic in it ends
//! this refresh as a failed read does, and the next spawn or edit reads again.

use std::sync::atomic::Ordering;

use super::{Outcome, REFRESHING, STATE, import, outcome, refresh};

pub(super) fn spawn() {
    crate::supervised::spawn_request(read(), async { settle(true) });
}

async fn read() {
    tracing::info!("shell startup files changed; reading the login environment again");
    import().await;
    let failed = outcome() == Outcome::Failed;
    settle(failed);
    if !failed {
        // An edit after the read's last check found REFRESHING set.
        refresh(false);
    }
}

/// Ends this refresh; a failed one is tried again at a later spawn or edit.
fn settle(failed: bool) {
    if failed {
        STATE.write().unwrap_or_else(|e| e.into_inner()).fingerprint = None;
    }
    REFRESHING.store(false, Ordering::SeqCst);
}
