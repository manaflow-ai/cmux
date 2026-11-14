//! One holder per signed-in user and team scope. A machine is passed to each transfer, while the
//! rotating local refresh cache stays one per scope.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use crate::broker::{Broker, CurrentScope, Launch};
use crate::error::{BrokerError, Error};
use crate::types::Scope;

#[derive(Default)]
struct Holders {
    brokers: HashMap<Scope, Arc<Broker>>,
    pending_cleanup: HashMap<Scope, Arc<Broker>>,
}

#[derive(Default)]
pub struct Registry {
    holders: Mutex<Holders>,
    /// The first wait before a failed renewal tries again (tests shorten it).
    pub renewal_retry_base: Option<Duration>,
}

impl Registry {
    fn lock(&self) -> MutexGuard<'_, Holders> {
        self.holders.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The scope's holder, made on first use. A retired holder whose erase failed is shut down
    /// again first; while that still fails, no replacement is made.
    pub async fn broker(
        &self,
        scope: &Scope,
        current_scope: CurrentScope,
        launch: Launch,
        home: PathBuf,
    ) -> Result<Arc<Broker>, Error> {
        let previous = self.lock().pending_cleanup.get(scope).cloned();
        if let Some(previous) = previous {
            if !previous.shutdown().await.is_empty() {
                return Err(BrokerError::RemoteDeliveryFailed.into());
            }
            self.lock().pending_cleanup.remove(scope);
        }
        let mut holders = self.lock();
        if let Some(broker) = holders.brokers.get(scope) {
            return Ok(broker.clone());
        }
        let base = self.renewal_retry_base.unwrap_or(Duration::from_secs(15));
        let broker = Broker::new(scope.clone(), current_scope, launch, home, base);
        holders.brokers.insert(scope.clone(), broker.clone());
        Ok(broker)
    }

    /// The existing holder, without making or signing in to one.
    pub fn existing(&self, scope: &Scope) -> Option<Arc<Broker>> {
        self.lock().brokers.get(scope).cloned()
    }

    pub fn has_pending_cleanup(&self, scope: &Scope) -> bool {
        self.lock().pending_cleanup.contains_key(scope)
    }

    /// Called only after the service deleted this machine.
    pub fn discard_deleted_target(&self, machine: &str, scope: &Scope) {
        let (live, retired) = {
            let holders = self.lock();
            (holders.brokers.get(scope).cloned(), holders.pending_cleanup.get(scope).cloned())
        };
        for broker in [live, retired].into_iter().flatten() {
            broker.discard_deleted_target(machine);
        }
    }

    /// Stops a scope's holder before releasing it. Credentials stay on disk.
    pub async fn remove(&self, scope: &Scope) -> HashSet<String> {
        let broker = {
            let mut holders = self.lock();
            let Some(broker) = holders
                .brokers
                .remove(scope)
                .or_else(|| holders.pending_cleanup.get(scope).cloned())
            else {
                return HashSet::new();
            };
            holders.pending_cleanup.insert(scope.clone(), broker.clone());
            broker
        };
        let failed = broker.shutdown().await;
        if failed.is_empty() {
            self.lock().pending_cleanup.remove(scope);
        }
        failed
    }
}
