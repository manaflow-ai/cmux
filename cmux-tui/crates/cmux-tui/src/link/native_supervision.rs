//! The daemon owns the Native receiving process and its exact remote entry.
//! Root role completion means the child has exited, not just acknowledged drain.

use cmux_process::{Command, Stdio};
use std::io;
use std::os::fd::AsRawFd as _;
use std::os::unix::net::UnixStream as StdStream;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use cmux_host::cloud::private_bootstrap::NativeBootstrap;
use cmux_host::cloud::receiver::REQUEST_BUDGET;
use cmux_link::caller::SupervisedChild;
use cmux_link::root_bootstrap::{Daemon, NativePermit};
use cmux_link::token::{StampChecks, VerifierConfig};
use cmux_tui_core::Mux;
use cmux_tui_core::server::{LinkVerifier, RemoteEntryServer, serve_remote_entry};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::UnixStream;
use zeroize::Zeroizing;

/// Only an authenticated root startup can select this entry's verifier. Keep
/// explicit legacy entry options on their existing startup path.
pub(crate) fn attach_native_receiver(
    root: Option<&mut Daemon>,
    legacy_entry: bool,
    mux: &Arc<Mux>,
    session: &Path,
) -> io::Result<bool> {
    if legacy_entry {
        return Ok(false);
    }
    let Some(root) = root else { return Ok(false) };
    let Some(permit) = root.native_permit() else { return Ok(false) };
    super::cloud_fs::install_if_cloud_host();
    mux.set_agent_transfer_host(super::cloud_fs::agent_transfer_host());
    let mux = mux.clone();
    let session = session.to_owned();
    root.attach_native(move |role, stopped| {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
        runtime
            .block_on(receive_role(permit.clone(), role, stopped, &mux, &session))
            .map_err(io::Error::other)
    })?;
    eprintln!("cmux link: token verifier mode control_plane: authenticated root startup");
    Ok(true)
}

async fn closed(stream: &mut UnixStream) -> anyhow::Result<()> {
    match stream.read_u8().await {
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => Ok(()),
        Err(error) => Err(error.into()),
        Ok(_) => anyhow::bail!("cloud.receiver.unexpected_role_data"),
    }
}

async fn read_frame(role: &mut UnixStream) -> anyhow::Result<Option<Zeroizing<Vec<u8>>>> {
    let result = read_complete_frame(role).await;
    match result {
        // Root may stop after sending the role fd but before finishing its
        // frame. No child exists yet, so EOF is already a completed stop.
        Err(error)
            if error
                .downcast_ref::<io::Error>()
                .is_some_and(|error| error.kind() == io::ErrorKind::UnexpectedEof) =>
        {
            Ok(None)
        }
        result => result.map(Some),
    }
}

async fn read_complete_frame(role: &mut UnixStream) -> anyhow::Result<Zeroizing<Vec<u8>>> {
    let mut prefix = [0; 4];
    role.read_exact(&mut prefix).await?;
    let length = NativeBootstrap::frame_length(prefix).map_err(anyhow::Error::msg)?;
    let mut frame = Zeroizing::new(vec![0; length]);
    frame[..4].copy_from_slice(&prefix);
    role.read_exact(&mut frame[4..]).await?;
    // Strict validation before starting a child; decoding itself grants no
    // authority. The child still fetches fresh original policy before READY.
    drop(NativeBootstrap::decode(&frame).map_err(anyhow::Error::msg)?);
    Ok(frame)
}

fn receiving_command(session: &Path) -> io::Result<Command> {
    let mut command = Command::new(std::env::current_exe()?);
    command.args(["link", "__receive-vm", "--session-socket"]).arg(session);
    Ok(command)
}

async fn receive_role(
    _permit: NativePermit,
    role: StdStream,
    stopped: StdStream,
    mux: &Arc<Mux>,
    session: &Path,
) -> anyhow::Result<()> {
    let notification = role.try_clone()?;
    role.set_nonblocking(true)?;
    stopped.set_nonblocking(true)?;
    let mut role = UnixStream::from_std(role)?;
    let mut notification = UnixStream::from_std(notification)?;
    let mut stopped = UnixStream::from_std(stopped)?;
    let frame = tokio::select! {
        biased;
        result = closed(&mut stopped) => return result,
        result = tokio::time::timeout(REQUEST_BUDGET, read_frame(&mut role)) => match result?? {
            Some(frame) => frame,
            None => return Ok(()),
        },
    };
    let canceled = async {
        tokio::select! {
            biased;
            result = closed(&mut stopped) => result,
            result = closed(&mut role) => result,
        }
    };
    tokio::pin!(canceled);
    let command = receiving_command(session)?;
    let mut child = tokio::select! {
        biased;
        result = &mut canceled => return result,
        result = tokio::time::timeout(REQUEST_BUDGET, NativeChild::start(command, mux, session, &frame)) => result??,
    };
    if let Err(error) = notification.write_all(&[2]).await {
        child.stop().await?;
        return Err(error.into());
    }
    tokio::select! {
        biased;
        result = &mut canceled => { child.stop().await?; result },
        _ = child.ended() => {
            // One frame owns exactly one process attempt. Remove ingress and
            // reap before the daemon reports completion; root must supply a
            // fresh generation rather than replaying this private frame.
            drop(child);
            Ok(())
        },
    }
}

struct NativeChild {
    child: Arc<SupervisedChild>,
    entry: Option<RemoteEntryServer>,
    lifetime: Option<UnixStream>,
    control: Option<UnixStream>,
}

impl NativeChild {
    async fn start(
        mut command: Command,
        mux: &Arc<Mux>,
        session: &Path,
        frame: &[u8],
    ) -> anyhow::Result<Self> {
        let (parent, inherited) = StdStream::pair()?;
        command
            .env_remove(cmux_link::token::VERIFIER_ENV)
            .stdin(Stdio::from(std::os::fd::OwnedFd::from(inherited)))
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        let child = SupervisedChild::capture(command.spawn()?)?;
        // Capture ownership before any further fallible operation. Cleanup
        // must not depend on the last admission-verifier Arc being dropped.
        let mut owned = Self { child: Arc::new(child), entry: None, lifetime: None, control: None };
        drop(command);
        parent.set_nonblocking(true)?;
        let parent = tokio::io::unix::AsyncFd::new(parent)?;
        let (tag, descriptor) = loop {
            let mut ready = parent.readable().await?;
            match ready.try_io(|parent| cmux_unix_socket::descriptor::receive(parent.get_ref(), 1))
            {
                Ok(result) => break result?,
                Err(_) => continue,
            }
        };
        if tag != [2] {
            anyhow::bail!("cloud.receiver.invalid_child_channel");
        }
        let control = StdStream::from(
            descriptor.ok_or_else(|| io::Error::other("cloud.receiver.missing_child_channel"))?,
        );
        // The inherited pair names its daemon creator. Only the returned,
        // child-created endpoint proves the writer's actual pid/start instance.
        owned.child.verify(&control)?;
        let checks =
            StampChecks::at_supervised_daemon_start(VerifierConfig::ControlPlane, &owned.child)?;
        let process = owned.child.clone();
        let verifier: LinkVerifier = Arc::new(move |stream| process.verify(stream));
        owned.entry = Some(serve_remote_entry(
            mux.clone(),
            &cmux_link::entry_path::remote_entry_socket_path(session),
            verifier,
            super::link_entry_gate(),
            checks,
        )?);
        // Entry and bootstrap use the same owned child. Check again immediately
        // before releasing the frame, after filesystem/listener setup.
        owned.child.verify(&control)?;
        control.set_nonblocking(true)?;
        owned.lifetime = Some(UnixStream::from_std(parent.into_inner())?);
        owned.control = Some(UnixStream::from_std(control)?);
        let control = owned.control.as_mut().expect("installed child control");
        control.write_all(frame).await?;
        if control.read_u8().await? != 1 {
            anyhow::bail!("cloud.receiver.invalid_readiness");
        }
        Ok(owned)
    }

    async fn ended(&mut self) {
        let control = self.control.as_mut().expect("installed child control");
        let lifetime = self.lifetime.as_mut().expect("installed child lifetime");
        tokio::select! {
            _ = wait_child(&self.child) => {},
            _ = closed(control) => {},
            _ = closed(lifetime) => {},
        }
    }

    async fn stop(mut self) -> anyhow::Result<()> {
        drop(self.entry.take());
        let control = self.control.as_mut().ok_or_else(|| io::Error::other("no child control"))?;
        let graceful = tokio::time::timeout(Duration::from_secs(8), async {
            control.shutdown().await?;
            if control.read_u8().await? != 2 {
                anyhow::bail!("cloud.receiver.invalid_drain_ack");
            }
            wait_child(&self.child).await?;
            anyhow::Ok(())
        })
        .await;
        // Drop is also the failure/cancellation path. An acknowledgement
        // cannot substitute for reaping, even with a retained verifier Arc.
        match graceful {
            Ok(result) => result,
            Err(_) => {
                Err(io::Error::new(io::ErrorKind::TimedOut, "cloud.receiver.stop_timeout").into())
            }
        }
    }
}

impl Drop for NativeChild {
    fn drop(&mut self) {
        drop(self.entry.take());
        for stream in [&self.control, &self.lifetime].into_iter().flatten() {
            // SAFETY: shutdown acts only on this owned connected socket.
            let _ = unsafe { libc::shutdown(stream.as_raw_fd(), libc::SHUT_RDWR) };
        }
        let _ = self.child.kill_and_wait();
    }
}

async fn wait_child(child: &SupervisedChild) -> io::Result<std::process::ExitStatus> {
    use std::os::fd::{FromRawFd as _, OwnedFd};
    if let Some(status) = child.try_wait()? {
        return Ok(status);
    }
    // The pid comes only from our retained Child. Recheck after opening:
    // another entry thread may have reaped it while opening the exit watch.
    // SAFETY: pidfd_open accepts this pid and flags zero, returning an owned fd.
    let raw = unsafe { libc::syscall(libc::SYS_pidfd_open, child.id(), 0) };
    let opened = if raw < 0 {
        Err(io::Error::last_os_error())
    } else {
        // SAFETY: raw is the fresh descriptor returned by pidfd_open.
        Ok(unsafe { OwnedFd::from_raw_fd(raw as i32) })
    };
    if let Some(status) = child.try_wait()? {
        return Ok(status);
    }
    let fd = tokio::io::unix::AsyncFd::new(opened?)?;
    let _ready = fd.readable().await?;
    child.try_wait()?.ok_or_else(|| io::Error::other("cloud.receiver.exit_not_reaped"))
}

#[cfg(test)]
mod tests;
