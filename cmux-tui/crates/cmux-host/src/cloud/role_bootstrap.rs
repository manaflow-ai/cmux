//! Preparing private receiving bootstrap belongs to the root Cloud worker.
use super::*;
use crate::cloud::receiver_files;

impl Worker {
    pub(super) fn drive_bootstrap(&mut self) {
        let Some(bridge) = &self.bootstrap else { return };
        bridge.drive();
        if self.bootstrap_retry_at.is_some_and(|at| at > self.now()) {
            return;
        }
        self.bootstrap_retry_at = None;
        let Some(live) = self.live.as_mut() else { return };
        // The opaque request pins both this role incarnation and the actual
        // authenticated daemon endpoint before the bounded original-self read.
        let Some(request) = bridge.prepare_native() else { return };
        let frame =
            receiver_files::bootstrap(&self.paths, &self.instance_id, &mut live.client, wall_ms())
                .and_then(|bootstrap| bootstrap.encode());
        if frame.is_ok_and(|frame| bridge.publish_native(request, frame)) {
            self.bootstrap_backoff.reset();
        } else {
            // Optional receiving failure does not stop status/activity. Retry
            // only after a real source/publication failure, with bounded backoff.
            self.bootstrap_retry_at =
                Some(self.now() + self.bootstrap_backoff.next(0, random_unit()));
        }
    }
}
