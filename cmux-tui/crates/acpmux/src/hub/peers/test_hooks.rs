use super::*;

#[cfg(test)]
pub(crate) struct PeerNoticeProjectionHook {
    reached: (StdMutex<bool>, std::sync::Condvar),
    released: (StdMutex<bool>, std::sync::Condvar),
}

#[cfg(test)]
impl PeerNoticeProjectionHook {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            reached: (StdMutex::new(false), std::sync::Condvar::new()),
            released: (StdMutex::new(false), std::sync::Condvar::new()),
        })
    }

    /// Waits, with a bound, for the projection to reach the hook; a test fails instead of
    /// hanging when it never does.
    pub(crate) fn wait_reached(&self) {
        assert!(
            self.wait_reached_timeout(std::time::Duration::from_secs(30)),
            "the peer notice projection never reached its hold"
        );
    }

    pub(crate) fn wait_reached_timeout(&self, timeout: std::time::Duration) -> bool {
        let reached = self.reached.0.lock().unwrap_or_else(|e| e.into_inner());
        let (reached, _) = self
            .reached
            .1
            .wait_timeout_while(reached, timeout, |reached| !*reached)
            .unwrap_or_else(|e| e.into_inner());
        *reached
    }

    pub(crate) fn release(&self) {
        *self.released.0.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.released.1.notify_all();
    }

    pub(crate) fn pause(&self) {
        *self.reached.0.lock().unwrap_or_else(|e| e.into_inner()) = true;
        self.reached.1.notify_all();
        let mut released = self.released.0.lock().unwrap_or_else(|e| e.into_inner());
        while !*released {
            released = self.released.1.wait(released).unwrap_or_else(|e| e.into_inner());
        }
    }
}

impl Hub {
    #[cfg(test)]
    pub(super) fn pause_after_peer_session_projection_for_test(&self) {
        let hook =
            self.peer_notice_projection_hook.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(hook) = hook {
            hook.pause();
        }
    }
}
