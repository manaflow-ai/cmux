//! Immediate ownership of a spawned PTY child until its reaper completes.

pub(crate) struct SpawnedPtyChild {
    child: Option<Box<dyn portable_pty::Child + Send + Sync>>,
}

impl SpawnedPtyChild {
    pub(crate) fn new(child: Box<dyn portable_pty::Child + Send + Sync>) -> Self {
        Self { child: Some(child) }
    }

    pub(crate) fn process_id(&self) -> Option<u32> {
        self.child.as_ref().expect("spawned PTY child is present").process_id()
    }

    pub(crate) fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> {
        self.child.as_ref().expect("spawned PTY child is present").clone_killer()
    }

    pub(crate) fn wait(&mut self) -> std::io::Result<portable_pty::ExitStatus> {
        let result = self.child.as_mut().expect("spawned PTY child is present").wait();
        if result.is_ok() {
            self.child.take();
        }
        result
    }

    /// Release a child only after stable identity proves that this process no
    /// longer owns its wait handle and the numeric PID belongs to no live
    /// process from the original publication.
    pub(crate) fn abandon_wait_ownership(mut self) {
        self.child.take();
    }
}

impl Drop for SpawnedPtyChild {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else { return };
        let _ = child.kill();
        let _ = child.wait();
    }
}
