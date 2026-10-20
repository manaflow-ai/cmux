//! Preparing private receiving bootstrap belongs to the root Cloud worker.
use super::*;

impl Worker {
    pub(super) fn drive_bootstrap(&mut self) {
        let Some(bridge) = &self.bootstrap else { return };
        bridge.drive();
        if self.bootstrap_retry_at.is_some_and(|at| at > self.now()) {
            return;
        }
        self.bootstrap_retry_at = None;
        let Some(live) = self.live.as_mut() else { return };
        match bridge.publish_original(&self.paths, &self.instance_id, &mut live.client, wall_ms()) {
            Ok(true) => self.bootstrap_backoff.reset(),
            Ok(false) => {}
            Err(_) => {
                // Optional receiving failure does not stop status/activity. Retry
                // only after a real source/publication failure, with bounded backoff.
                self.bootstrap_retry_at =
                    Some(self.now() + self.bootstrap_backoff.next(0, random_unit()));
            }
        }
    }
}
