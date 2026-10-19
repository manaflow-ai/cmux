//! The host replica publisher's asks for a new install token
//! (`cloud-host-replica-needed`; split from host_replica.rs for the god-file budget).

use std::sync::PoisonError;

use super::super::stream::CloudEvent;
use super::Inner;

impl Inner {
    /// Asks the app for a new lease: once per lease and reason, and again
    /// after `reask` (an app connection may have missed it). An `expiring`
    /// ask also waits `reask` after the last `expiring` ask of any lease, so
    /// a Mac clock ahead of the cloud's (every new token then reads as
    /// expiring) asks at that pace, not in a loop.
    pub(super) fn need(&self, reason: &'static str) {
        let now = (self.options.now_ms)();
        let reask = u64::try_from(self.options.reask.as_millis()).unwrap_or(u64::MAX);
        let expires_at = {
            let mut state = self.lock();
            let Some(expires_at) = state.lease.as_ref().map(|lease| lease.expires_at) else {
                return;
            };
            if let Some((asked_expiry, asked_reason, at)) = state.asked {
                let same = asked_expiry == expires_at && asked_reason == reason;
                let paced = reason == "expiring" && asked_reason == "expiring";
                if (same || paced) && now.saturating_sub(at) < reask {
                    return;
                }
            }
            state.asked = Some((expires_at, reason, now));
            expires_at
        };
        let sink = self.sink.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(sink) = sink {
            sink(CloudEvent::HostReplicaNeeded { reason, expires_at: Some(expires_at) });
        }
    }

    /// Asks for a new lease when this one ends within `refresh_lead`.
    pub(super) fn need_if_expiring(&self, expires_at: u64) {
        let lead = u64::try_from(self.options.refresh_lead.as_millis()).unwrap_or(u64::MAX);
        if (self.options.now_ms)().saturating_add(lead) >= expires_at {
            self.need("expiring");
        }
    }
}
