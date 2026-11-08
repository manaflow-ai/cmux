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
            Ok(true) if bridge.is_ready() => {
                self.bootstrap_backoff.reset();
                if self.bootstrap_last_error.take().is_some() {
                    log("Native receiving ready after earlier failures");
                }
            }
            Ok(_) => {}
            Err(error) => {
                // Optional receiving failure does not stop status/activity. Retry
                // only after a real source/publication failure, with bounded backoff.
                let delay = self.bootstrap_backoff.next(0, random_unit());
                self.bootstrap_retry_at = Some(self.now() + delay);
                // The reasons are fixed texts or server error codes, never keys or
                // tokens. Each new one is logged once, with when it is retried.
                if let Some(line) = new_failure(&mut self.bootstrap_last_error, &error) {
                    log(&format!("Native receiving failed: {line} (retry in {delay} ms)"));
                }
            }
        }
    }
}

/// `error` cut to one bounded line, when it differs from the last one logged.
fn new_failure(last: &mut Option<String>, error: &str) -> Option<String> {
    let line: String =
        error.chars().map(|c| if c.is_control() { ' ' } else { c }).take(300).collect();
    if last.as_deref() == Some(line.as_str()) {
        return None;
    }
    *last = Some(line.clone());
    Some(line)
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

#[cfg(test)]
mod tests {
    use super::new_failure;

    #[test]
    fn each_new_receiving_failure_is_logged_once() {
        let mut last = None;
        assert_eq!(
            new_failure(&mut last, "protected VM identity changed").as_deref(),
            Some("protected VM identity changed")
        );
        assert_eq!(new_failure(&mut last, "protected VM identity changed"), None);
        assert_eq!(
            new_failure(&mut last, "owner.unreachable\nnext").as_deref(),
            Some("owner.unreachable next")
        );
        let long = "x".repeat(1000);
        assert_eq!(new_failure(&mut last, &long).map(|l| l.len()), Some(300));
    }
}
