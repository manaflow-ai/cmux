//! A PTY child for the CLI tests: its output is drained (so the child never
//! blocks on a full PTY) and the latest part kept for failure messages.

use super::*;

#[cfg(unix)]
pub(super) struct PtyChild {
    pub(super) child: Option<Box<dyn cmux_pty::Child + Send + Sync>>,
    pub(super) output_drain: Option<std::thread::JoinHandle<()>>,
    /// The last [`PTY_OUTPUT_TAIL_BYTES`] the child wrote (stdout and stderr
    /// share the PTY), for failure messages.
    pub(super) output_tail: std::sync::Arc<std::sync::Mutex<std::collections::VecDeque<u8>>>,
}

/// How much of a PTY child's output a failure message shows.
#[cfg(unix)]
const PTY_OUTPUT_TAIL_BYTES: usize = 16 * 1024;

#[cfg(unix)]
impl PtyChild {
    pub(super) fn start(args: &[&str]) -> Self {
        Self::start_with_env(args, &[])
    }

    pub(super) fn start_with_env(args: &[&str], env: &[(&str, &std::ffi::OsStr)]) -> Self {
        let spawned = spawn_pty_child(args, env);
        let mut master = spawned.master.try_clone_reader().unwrap();
        let output_tail =
            std::sync::Arc::new(std::sync::Mutex::new(std::collections::VecDeque::new()));
        let tail = output_tail.clone();
        let output_drain = std::thread::spawn(move || {
            let mut buffer = [0; 8192];
            while let Ok(read) = master.read(&mut buffer) {
                if read == 0 {
                    break;
                }
                let mut tail = tail.lock().unwrap();
                tail.extend(&buffer[..read]);
                let excess = tail.len().saturating_sub(PTY_OUTPUT_TAIL_BYTES);
                tail.drain(..excess);
            }
        });
        Self { child: Some(spawned.child), output_drain: Some(output_drain), output_tail }
    }

    /// The child's latest output as text, escape sequences included, for a
    /// failure message.
    pub(super) fn output_tail(&self) -> String {
        let tail = self.output_tail.lock().unwrap();
        String::from_utf8_lossy(&tail.iter().copied().collect::<Vec<_>>()).into_owned()
    }

    pub(super) fn wait_for_exit(&mut self, timeout: Duration) -> Option<cmux_pty::ExitStatus> {
        let mut child = self.child.take().expect("PTY child already has an exit waiter");
        let mut killer = child.clone_killer();
        let (sender, receiver) = mpsc::sync_channel(1);
        let _waiter = std::thread::spawn(move || {
            let _ = sender.send(child.wait());
        });
        match receiver.recv_timeout(timeout) {
            Ok(status) => Some(status.unwrap()),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let _ = killer.kill();
                match receiver.recv_timeout(Duration::from_secs(5)) {
                    Ok(Ok(_)) => {}
                    Ok(Err(error)) => {
                        panic!("interactive owner did not exit cleanly after kill: {error}");
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        let _ = self.output_drain.take();
                        panic!("interactive owner did not exit after kill");
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        let _ = self.output_drain.take();
                        panic!("interactive owner exit waiter disconnected after kill");
                    }
                }
                None
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let _ = self.output_drain.take();
                panic!("interactive owner exit waiter disconnected")
            }
        }
    }
}

#[cfg(unix)]
impl Drop for PtyChild {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(output_drain) = self.output_drain.take() {
            let _ = output_drain.join();
        }
    }
}
