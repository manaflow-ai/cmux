//! Socket replacement detaches old inventory leases before admitting new ones.
use super::AgentSessions;
use std::path::{Path, PathBuf};

#[derive(Default)]
pub(super) struct SocketState {
    path: Option<PathBuf>,
    generation: u64,
}

impl AgentSessions {
    pub(crate) fn set_socket(&self, socket: Option<PathBuf>) {
        let retired = {
            let mut current = self.socket.write().unwrap_or_else(|e| e.into_inner());
            if current.path == socket {
                return;
            }
            // Never wrap an epoch back onto a still-running admission.
            if let Some(next) = current.generation.checked_add(1) {
                current.generation = next;
                current.path = socket;
            } else {
                current.path = None;
            }
            self.inventory_watches.take_all()
        };
        #[cfg(test)]
        {
            let hook = self.inventory_socket_hook.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some(hook) = hook {
                hook();
            }
        }
        // Closing a link may invoke callbacks that read the socket. Release
        // the write guard first; close only the leases detached above.
        retired.close();
    }

    pub(crate) fn socket(&self) -> Option<PathBuf> {
        self.socket.read().unwrap_or_else(|e| e.into_inner()).path.clone()
    }

    pub(in crate::server) fn inventory_socket(&self) -> Option<(PathBuf, u64)> {
        let current = self.socket.read().unwrap_or_else(|e| e.into_inner());
        current.path.clone().map(|path| (path, current.generation))
    }

    #[cfg(test)]
    pub(in crate::server) fn set_inventory_socket_test_hook(&self, hook: Box<dyn FnOnce() + Send>) {
        *self.inventory_socket_hook.lock().unwrap_or_else(|e| e.into_inner()) = Some(hook);
    }

    /// Orders receipts and invalidations before replacement, including ABA.
    pub(in crate::server) fn with_inventory_socket<T>(
        &self,
        expected: &Path,
        generation: u64,
        action: impl FnOnce() -> T,
    ) -> Option<T> {
        let current = self.socket.read().unwrap_or_else(|e| e.into_inner());
        (current.path.as_deref() == Some(expected) && current.generation == generation).then(action)
    }
}
