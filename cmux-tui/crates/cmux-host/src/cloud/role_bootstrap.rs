//! Preparing private receiving bootstrap belongs to the root Cloud worker.
use super::*;

impl Worker {
    pub(super) fn drive_bootstrap(&mut self) {
        let now = self.now();
        let Some(bridge) = &mut self.bootstrap else { return };
        bridge.drive();
        if self.bootstrap_retry_at.is_some_and(|at| at > now) {
            return;
        }
        self.bootstrap_retry_at = None;
        let Some(live) = self.live.as_mut() else { return };
        match bridge.publish_original(&self.paths, &self.instance_id, &mut live.client, wall_ms()) {
            Ok(true) if bridge.is_ready() => self.bootstrap_backoff.reset(),
            Ok(_) => {}
            Err(_) => {
                // Optional receiving failure does not stop status/activity. Retry
                // only after a real source/publication failure, with bounded backoff.
                self.bootstrap_retry_at =
                    Some(self.now() + self.bootstrap_backoff.next(0, random_unit()));
            }
        }
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        if let (Some(bridge), Some(live)) = (self.bootstrap.as_mut(), self.live.as_mut())
            && bridge.retire(&mut live.client, wall_ms()).is_err()
        {
            log("Native receiving retirement unavailable");
        }
    }
}
