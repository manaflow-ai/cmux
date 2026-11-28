//! An updater gets the gap between turns using the same CLI on this daemon. While a turn
//! waits for a child session, the child must still be allowed to run. Only an installation
//! that actually acquired the exclusive guard holds new turns.
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError, Weak};
use tokio::sync::{Notify, OwnedRwLockReadGuard, OwnedRwLockWriteGuard, RwLock};

#[derive(Default)]
pub(crate) struct InstallTurns(Mutex<HashMap<String, Weak<Program>>>);

#[derive(Default)]
pub(crate) struct Program {
    gate: Arc<RwLock<()>>,
    ended: Notify,
}

pub(crate) struct Turn {
    // Release this before waking waiting updaters.
    guard: Option<OwnedRwLockReadGuard<()>>,
    program: Arc<Program>,
}

impl Drop for Turn {
    fn drop(&mut self) {
        drop(self.guard.take());
        self.program.ended.notify_waiters();
    }
}

pub(super) struct Install {
    guard: Option<OwnedRwLockWriteGuard<()>>,
    program: Arc<Program>,
}

impl Drop for Install {
    fn drop(&mut self) {
        drop(self.guard.take());
        self.program.ended.notify_waiters();
    }
}

impl InstallTurns {
    pub(crate) fn program(&self, executable: &str) -> Arc<Program> {
        let name = Path::new(executable).file_name().and_then(|s| s.to_str()).unwrap_or(executable);
        let mut programs = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(existing) = programs.get(name).and_then(Weak::upgrade) {
            return existing;
        }
        programs.retain(|_, p| p.strong_count() != 0);
        let program = Arc::new(Program::default());
        programs.insert(name.to_owned(), Arc::downgrade(&program));
        program
    }
}

impl Program {
    pub(crate) async fn turn(self: Arc<Self>) -> Turn {
        let guard = self.gate.clone().read_owned().await;
        Turn { guard: Some(guard), program: self }
    }

    pub(super) async fn install(self: &Arc<Self>) -> Install {
        loop {
            let ended = self.ended.notified();
            if let Ok(guard) = self.gate.clone().try_write_owned() {
                return Install { guard: Some(guard), program: self.clone() };
            }
            ended.await;
        }
    }
}

#[cfg(test)]
#[path = "turns_tests.rs"]
mod tests;
