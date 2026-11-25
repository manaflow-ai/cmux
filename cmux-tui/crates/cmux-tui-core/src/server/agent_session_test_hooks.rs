use super::*;

impl AgentSessions {
    /// Turns the stage S1 publication of the proxy authors on or off (tests).
    #[cfg(test)]
    pub(crate) fn set_publishing_for_test(&self, on: bool) {
        self.proxy_authors.set_publishing_for_test(on);
    }

    /// Runs `hold` while this thread holds the host proxy authors (tests that prove a key does not wait for them).
    #[cfg(test)]
    pub(crate) fn hold_proxy_authors_for_test(&self, hold: &dyn Fn()) {
        let _held = self.proxy_authors.lock().unwrap_or_else(|e| e.into_inner());
        hold();
    }

    #[cfg(test)]
    pub(crate) fn attachment_count(&self) -> usize {
        self.lock().attachments.len()
    }
}
