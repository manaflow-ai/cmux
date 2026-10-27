//! The process trees of the hooks that run now. Shutdown ends each one, so a
//! hook worker's waits (its stdin, its exit) return on that event instead of
//! re-reading the cancel flag on a period. Chrome ends a child the same way
//! at shutdown: `content/browser/child_process_launcher.cc` terminates the
//! process, and the exit is the event its waiters see.

use std::collections::HashMap;

#[cfg(windows)]
use windows_sys::Win32::Foundation::HANDLE;
#[cfg(windows)]
use windows_sys::Win32::System::JobObjects::TerminateJobObject;

use super::JournalHookRuntime;
use crate::panic_free::RecoverPoison;

/// One running hook's process tree.
#[derive(Clone, Copy)]
pub(super) struct HookTree {
    /// The hook's own process group: its scope starts it in a fresh one and
    /// fences its descendants in it.
    #[cfg(unix)]
    pub(super) group: libc::pid_t,
    /// The job object of the hook and its descendants, as an integer (a
    /// kernel handle is process-wide; `HANDLE` is not `Send`).
    #[cfg(windows)]
    pub(super) job: usize,
}

impl HookTree {
    fn end(self) {
        // SAFETY: kill takes plain integers and touches no memory. The group
        // leader stays unreaped while its tree is watched, so the id still
        // names this hook's group.
        #[cfg(unix)]
        unsafe {
            libc::kill(-self.group, libc::SIGKILL);
        }
        // SAFETY: the worker keeps the job handle open while its tree is
        // watched; the watch ends before the job drops.
        #[cfg(windows)]
        unsafe {
            TerminateJobObject(self.job as HANDLE, 1);
        }
    }
}

/// The watched trees, inside the runtime's state lock.
#[derive(Default)]
pub(super) struct HookTrees {
    trees: HashMap<u64, HookTree>,
    next: u64,
}

impl HookTrees {
    /// Ends every watched tree (shutdown).
    pub(super) fn end_all(&self) {
        for tree in self.trees.values() {
            tree.end();
        }
    }

    #[cfg(test)]
    pub(super) fn is_empty(&self) -> bool {
        self.trees.is_empty()
    }
}

/// Keeps one hook tree in [`JournalHookRuntime`] until it drops. Drop it
/// before the hook's leader is reaped (unix) or its job closes (Windows).
pub(super) struct HookTreeWatch<'a> {
    runtime: &'a JournalHookRuntime,
    id: u64,
}

impl Drop for HookTreeWatch<'_> {
    fn drop(&mut self) {
        self.runtime.state.lock().recover_poison().trees.trees.remove(&self.id);
    }
}

impl JournalHookRuntime {
    /// Watches `tree` until the returned guard drops. `None` once shutdown
    /// began: the caller ends its tree itself.
    pub(super) fn watch(&self, tree: HookTree) -> Option<HookTreeWatch<'_>> {
        let mut state = self.state.lock().recover_poison();
        // `shutdown_until` sets the flag before it takes this lock to end
        // the watched trees, so a tree added here is either ended there or
        // refused here.
        if self.is_cancelled() {
            return None;
        }
        let trees = &mut state.trees;
        let id = trees.next;
        trees.next = id.wrapping_add(1);
        trees.trees.insert(id, tree);
        Some(HookTreeWatch { runtime: self, id })
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::time::{Duration, Instant};

    use cmux_process::Stdio;

    use super::*;
    use crate::journal_hooks::SHUTDOWN_WAIT;

    #[test]
    fn shutdown_ends_every_watched_hook_tree() {
        let mut child = cmux_process::Command::new("/bin/sleep")
            .arg("30")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .unwrap();
        let runtime = JournalHookRuntime::default();
        let group = libc::pid_t::try_from(child.id()).unwrap();
        let watch = runtime.watch(HookTree { group }).expect("no shutdown began");

        assert!(runtime.shutdown_until(Instant::now() + SHUTDOWN_WAIT));
        drop(watch);
        let status = child.wait_timeout(Duration::from_secs(5)).unwrap();
        assert!(status.is_some_and(|status| !status.success()), "shutdown left the hook running");
    }

    #[test]
    fn a_hook_tree_after_shutdown_is_refused() {
        let runtime = JournalHookRuntime::default();
        assert!(runtime.shutdown_until(Instant::now()));
        assert!(runtime.watch(HookTree { group: libc::pid_t::MAX }).is_none());
        assert!(runtime.state.lock().recover_poison().trees.is_empty());
    }

    #[test]
    fn a_finished_hook_leaves_no_tree_behind() {
        let runtime = JournalHookRuntime::default();
        let watch = runtime.watch(HookTree { group: libc::pid_t::MAX }).unwrap();
        assert_eq!(runtime.state.lock().recover_poison().trees.trees.len(), 1);
        drop(watch);
        assert!(runtime.state.lock().recover_poison().trees.is_empty());
    }
}
