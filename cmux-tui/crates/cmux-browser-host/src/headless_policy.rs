//! BR-R3 on the shared headless browser (cx-d0d.79, coordinator call
//! 2026-10-12): a session under a domain policy gets a policy listener
//! (crate::policy_proxy) and a policy store whose connections go through it
//! (crate::headless_configure), so a WebSocket to a host the policy does
//! not allow never leaves the browser. The listener reads the session's
//! live policy; clearing the policy lets every host through again, and the
//! store stays.
//!
//! Tabs from before the policy are outside the store: the session engine
//! reopens the tabs it created there (crate::provider_engine), and any
//! other tab refuses the session's calls but `tabs.close` while the policy
//! is set, so no page the session drives keeps a way out.

use crate::headless_source::HeadlessSource;
use crate::policy_proxy::{ConnectionPolicy, PolicyListener};
use crate::protocol::{DriverError, ErrorCode};
use std::collections::HashMap;
use std::sync::PoisonError;

/// Each session's policy listener and store.
#[derive(Default)]
pub struct Policies {
    sessions: HashMap<u64, SessionPolicy>,
}

struct SessionPolicy {
    listener: PolicyListener,
    store: String,
    /// Whether the policy is set now (the store outlives a cleared one).
    active: bool,
}

impl HeadlessSource {
    fn policies(&self) -> std::sync::MutexGuard<'_, Policies> {
        self.policies.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The session's connection policy. True when its new tabs just moved
    /// to the policy store (the first policy of the session).
    pub(crate) fn set_connection_policy(
        &self,
        session: u64,
        policy: Option<ConnectionPolicy>,
    ) -> Result<bool, DriverError> {
        if let Some(current) = self.policies().sessions.get_mut(&session) {
            current.active = policy.is_some();
            current.listener.set_policy(policy);
            return Ok(false);
        }
        let Some(policy) = policy else { return Ok(false) };
        let listener = PolicyListener::start(Some(policy), self.egress).map_err(|e| {
            DriverError::closed(format!("the session's policy listener did not start: {e}"))
        })?;
        let store = self.policy_store(session, &listener.proxy_server())?;
        self.policies().sessions.insert(session, SessionPolicy { listener, store, active: true });
        Ok(true)
    }

    /// Whether `target` is outside the session's policy store while its
    /// policy is set.
    pub(crate) fn outside_connection_policy(&self, session: u64, target: &str) -> bool {
        let store = match self.policies().sessions.get(&session) {
            Some(policy) if policy.active => policy.store.clone(),
            _ => return false,
        };
        self.driver.tab_context(target).as_deref() != Some(store.as_str())
    }

    /// Refuses the session's call on a tab outside its policy store
    /// (`tabs.close` passes).
    pub(crate) fn connection_policy_refusal(
        &self,
        session: u64,
        method: &str,
        target: &str,
    ) -> Result<(), DriverError> {
        if method == "tabs.close" || !self.outside_connection_policy(session, target) {
            return Ok(());
        }
        Err(DriverError::new(
            ErrorCode::Forbidden,
            "this tab opened before the session's domain policy and its connections are not checked; open a new tab",
        ))
    }

    /// The session ended: its listener stops (its store closes with the
    /// session's other stores).
    pub(crate) fn connection_policy_ended(&self, session: u64) {
        self.policies().sessions.remove(&session);
    }
}
