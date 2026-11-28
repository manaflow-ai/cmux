//! The fork's end of a run VM's command ([`ShellHarness`]) and what the parent needs to replay it
//! exactly: the command runs as `sh -c CMD`, nothing added, with the caller's environment
//! (`run_vm_env.rs`), and its stdout and stderr come back as raw bytes, each on its own fd. When the
//! caller's stdout and stderr are one file ([`same_file`]), the fork gives the command one pipe for
//! both, so the order it wrote them in is the order they come back.

use super::sub_fork_run::Harness;
use super::sub_fork_wire::{B64, Frame, Job};

/// The most one [`Frame::Bytes`] carries: a read's worth, sent as it came.
const CHUNK: usize = 64 * 1024;

/// The fork's end for a command job: `sh -c CMD` in the job's directory, its output as raw
/// [`Frame::Bytes`], the exit code (a signal is 128 + its number).
pub struct ShellHarness;

#[cfg(unix)]
impl Harness for ShellHarness {
    async fn run(&self, job: &Job, out: &mut (dyn FnMut(Frame) + Send)) -> Result<i32, String> {
        use std::os::fd::OwnedFd;
        let command = job.command.as_deref().ok_or("no command")?;
        let mut cmd = cmux_process::Command::new("/bin/sh");
        cmd.arg("-c").arg(command);
        cmd.current_dir(job.cwd.as_deref().unwrap_or(&job.checkout));
        if job.env.is_empty() {
            // A job from before `env`: the fork's own environment and the caller's PATH.
            if let Some(path) = job.path.as_deref().filter(|p| !p.is_empty()) {
                cmd.env("PATH", path);
            }
        } else {
            let sent: Vec<Vec<u8>> = job.env.iter().map(|kv| kv.0.clone()).collect();
            cmd.env_clear()
                .envs(super::run_vm_env::fork_env(&sent, &job.env_held, |k| std::env::var_os(k)));
        }
        // Decided: a shim under it (a build script's `cc`, `make`'s `cargo`) runs the real
        // program here, on the run VM, never routes again (`exec_router.rs`). The same value as
        // a command kept on its own machine, so the two read the same environment.
        cmd.env(super::exec_router::ROUTED_ENV, "here");
        let pipe = || std::io::pipe().map_err(|e| format!("pipe: {e}"));
        let mut readers = Vec::new();
        if job.merged {
            let (r, w) = pipe()?;
            let w2 = w.try_clone().map_err(|e| format!("pipe: {e}"))?;
            cmd.stdout(OwnedFd::from(w)).stderr(OwnedFd::from(w2));
            readers.push((1u8, r));
        } else {
            let ((r1, w1), (r2, w2)) = (pipe()?, pipe()?);
            cmd.stdout(OwnedFd::from(w1)).stderr(OwnedFd::from(w2));
            readers.extend([(1u8, r1), (2u8, r2)]);
        }
        // Its own group: dropped mid-run (the stream gone), the child ends the whole command.
        cmd.process_group(0).stdin(cmux_process::Stdio::null());
        let mut child = cmd.spawn().map_err(|e| format!("sh: {e}"))?;
        // The write ends live only in the child now, so the reads end when it does.
        drop(cmd);
        // Blocking readers hand chunks over; the child stays here, so a drop ends it.
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(u8, Vec<u8>)>();
        let mut joins = Vec::new();
        for (fd, mut r) in readers {
            let tx = tx.clone();
            joins.push(tokio::task::spawn_blocking(move || {
                use std::io::Read as _;
                let mut buf = vec![0u8; CHUNK];
                loop {
                    match r.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            if tx.send((fd, buf.get(..n).unwrap_or(&buf).to_vec())).is_err() {
                                break;
                            }
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                        Err(_) => break,
                    }
                }
            }));
        }
        drop(tx);
        while let Some((fd, data)) = rx.recv().await {
            out(Frame::Bytes { fd, data: B64(data) });
        }
        for j in joins {
            let _ = j.await;
        }
        // Its output closed: the shell is ending, so this wait is short.
        let status = child.wait().map_err(|e| format!("sh: {e}"))?;
        Ok(exit_code(status))
    }
}

#[cfg(not(unix))]
impl Harness for ShellHarness {
    async fn run(&self, _job: &Job, _out: &mut (dyn FnMut(Frame) + Send)) -> Result<i32, String> {
        Err("a run VM's command needs a unix fork".into())
    }
}

/// A process's exit code: a signal is 128 + its number, as a shell reports it.
pub fn exit_code(status: std::process::ExitStatus) -> i32 {
    #[cfg(unix)]
    {
        use std::os::unix::process::ExitStatusExt as _;
        if let Some(sig) = status.signal() {
            return 128 + sig;
        }
    }
    status.code().unwrap_or(1)
}

/// Whether two descriptors are one open file (one pipe, one terminal, one log): the caller's
/// stdout and stderr when its shell said `2>&1`.
#[cfg(unix)]
pub fn same_file(a: std::os::fd::BorrowedFd<'_>, b: std::os::fd::BorrowedFd<'_>) -> bool {
    use std::os::unix::fs::MetadataExt as _;
    let id = |fd: std::os::fd::BorrowedFd<'_>| {
        let f = std::fs::File::from(fd.try_clone_to_owned().ok()?);
        let m = f.metadata().ok()?;
        Some((m.dev(), m.ino()))
    };
    matches!((id(a), id(b)), (Some(x), Some(y)) if x == y)
}

/// Whether this process's stdout and stderr are one file ([`same_file`]).
#[cfg(unix)]
pub fn stdio_merged() -> bool {
    use std::os::fd::AsFd as _;
    same_file(std::io::stdout().as_fd(), std::io::stderr().as_fd())
}
