//! Test doubles for PTY surfaces: in-memory and fd-backed master PTYs, child
//! killers and a startup child whose exit the test controls.

use super::*;

#[cfg(test)]
pub(super) struct TestMasterPty {
    pub(super) size: Mutex<PtySize>,
    pub(super) control: Arc<TestMasterPtyControl>,
}

#[cfg(test)]
#[derive(Default)]
pub(super) struct TestMasterPtyControl {
    pub(super) fail_next_resize: AtomicBool,
}

#[cfg(test)]
impl MasterPty for TestMasterPty {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        if self.control.fail_next_resize.swap(false, Ordering::AcqRel) {
            anyhow::bail!("injected PTY master resize failure");
        }
        *self.size.lock().unwrap() = size;
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        Ok(*self.size.lock().unwrap())
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(std::io::empty()))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        Ok(Box::new(std::io::sink()))
    }

    #[cfg(unix)]
    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    #[cfg(unix)]
    fn as_raw_fd(&self) -> Option<std::os::unix::io::RawFd> {
        None
    }

    #[cfg(unix)]
    fn tty_name(&self) -> Option<PathBuf> {
        None
    }
}

#[cfg(all(test, unix))]
pub(super) struct FdMasterPty {
    pub(super) file: std::fs::File,
    pub(super) size: Mutex<PtySize>,
}

#[cfg(all(test, unix))]
impl MasterPty for FdMasterPty {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        *self.size.lock().unwrap() = size;
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        Ok(*self.size.lock().unwrap())
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(std::io::empty()))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        Ok(Box::new(std::io::sink()))
    }

    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    fn as_raw_fd(&self) -> Option<std::os::unix::io::RawFd> {
        use std::os::fd::AsRawFd;
        Some(self.file.as_raw_fd())
    }

    fn tty_name(&self) -> Option<PathBuf> {
        None
    }
}

#[cfg(test)]
#[derive(Debug)]
pub(super) struct TestChildKiller;

#[cfg(test)]
impl ChildKiller for TestChildKiller {
    fn kill(&mut self) -> std::io::Result<()> {
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(TestChildKiller)
    }
}

#[cfg(test)]
#[derive(Debug, Default)]
pub(super) struct StartupChildState {
    pub(super) kill_count: AtomicUsize,
    pub(super) wait_count: AtomicUsize,
}

#[cfg(test)]
#[derive(Debug)]
pub(super) struct StartupChild {
    pub(super) state: Arc<StartupChildState>,
}

#[cfg(test)]
impl ChildKiller for StartupChild {
    fn kill(&mut self) -> std::io::Result<()> {
        self.state.kill_count.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }

    fn clone_killer(&self) -> Box<dyn ChildKiller + Send + Sync> {
        Box::new(TestChildKiller)
    }
}

#[cfg(test)]
impl cmux_pty::Child for StartupChild {
    fn try_wait(&mut self) -> std::io::Result<Option<cmux_pty::ExitStatus>> {
        Err(std::io::Error::other("test child has no process"))
    }

    fn wait(&mut self) -> std::io::Result<cmux_pty::ExitStatus> {
        self.state.wait_count.fetch_add(1, Ordering::Relaxed);
        Err(std::io::Error::other("test child has no process"))
    }

    fn process_id(&self) -> Option<u32> {
        None
    }

    #[cfg(windows)]
    fn as_raw_handle(&self) -> Option<std::os::windows::io::RawHandle> {
        None
    }
}
