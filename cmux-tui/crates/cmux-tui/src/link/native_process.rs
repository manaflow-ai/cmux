//! The receiving child has one mode, fixed by its private daemon startup.
//! It reads no user link state and never receives an account credential.
use std::os::fd::AsRawFd as _;
use std::os::unix::net::UnixStream as StdStream;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail};
use cmux_host::cloud::private_bootstrap::NativeBootstrap;
use cmux_host::cloud::receiver::{REQUEST_BUDGET, ReceiverSnapshot};
use cmux_host::cloud::receiver_agent::AgentReceiver;
use cmux_link::elapsed::{Deadline, Elapsed};
use cmux_link::native_token::NativePolicy;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::{UdpSocket, UnixStream};
use tokio::sync::{mpsc, oneshot};
use zeroize::Zeroizing;

use super::native_receiver::NativeReceiver;

struct Authority(Arc<AgentReceiver>);
impl Drop for Authority {
    fn drop(&mut self) {
        // Blocking work can outlive its async waiter. Its intent was prepared
        // before scheduling; fence it before the receiver lifetime disappears.
        self.0.invalidate();
    }
}

pub(super) fn run(flags: &super::Flags) -> anyhow::Result<()> {
    let session = PathBuf::from(super::required(flags, "--session-socket")?);
    let parent = super::cloud_broker::inherited("0")?;
    // The dedicated exec must protect its own address space before returning
    // the endpoint over which its daemon will release private bootstrap data.
    cmux_link::caller::protect_private_process()?;
    parent.set_write_timeout(Some(REQUEST_BUDGET))?;
    let (control, daemon) = StdStream::pair()?;
    // A child-created descriptor lets the daemon authenticate its exact owned
    // process before forwarding the root's original WG bootstrap.
    cmux_unix_socket::descriptor::send(&parent, &[2], daemon.as_raw_fd())?;
    drop(daemon);
    parent.set_nonblocking(true)?;
    control.set_nonblocking(true)?;
    let runtime = super::tokio_runtime()?;
    let result = runtime.block_on(run_child(parent, control, session));
    // This runtime belongs to the dedicated child. Its authority is fenced
    // and service futures are drained before return; an abandoned blocking
    // public-policy read must not keep the child from exiting and being reaped.
    runtime.shutdown_timeout(Duration::from_secs(1));
    result
}

async fn closed(stream: &mut UnixStream) -> anyhow::Result<()> {
    match stream.read(&mut [0]).await {
        Ok(0) => Ok(()),
        Ok(_) => bail!("cloud.receiver.unexpected_control_data"),
        Err(error) => Err(error.into()),
    }
}

async fn read_bootstrap(control: &mut UnixStream) -> anyhow::Result<NativeBootstrap> {
    let mut prefix = [0; 4];
    control.read_exact(&mut prefix).await?;
    let length = NativeBootstrap::frame_length(prefix).map_err(|error| anyhow!(error))?;
    let mut frame = Zeroizing::new(vec![0; length]);
    let (head, body) = frame
        .split_at_mut_checked(4)
        .ok_or_else(|| anyhow!("cloud.receiver.invalid_bootstrap_frame"))?;
    head.copy_from_slice(&prefix);
    control.read_exact(body).await?;
    NativeBootstrap::decode(&frame).map_err(|error| anyhow!(error))
}

async fn refresh(source: &Arc<AgentReceiver>) -> anyhow::Result<ReceiverSnapshot> {
    // Intent creation belongs to the live actor, not to the blocking executor.
    // A delayed executor must never create fresh authority after role stop.
    let prepared = source.prepare_refresh().map_err(|error| anyhow!(error))?;
    let active = prepared.started() + REQUEST_BUDGET;
    let elapsed = prepared
        .elapsed_source()
        .and_then(|source| source.deadline_at(REQUEST_BUDGET))
        .ok_or_else(|| anyhow!("cloud.receiver.policy_unavailable"))?;
    let reader = source.clone();
    let mut task = tokio::task::spawn_blocking(move || reader.refresh_prepared(prepared));
    let result = tokio::select! {
        biased;
        _ = super::receiver_deadline::wait(active, Some(elapsed)) => None,
        result = &mut task => Some(result),
    };
    match result {
        Some(Ok(Ok(snapshot))) => Ok(snapshot),
        _ => {
            source.invalidate();
            bail!("cloud.receiver.policy_unavailable")
        }
    }
}

async fn initialize(
    bootstrap: NativeBootstrap,
    session: PathBuf,
) -> anyhow::Result<(Authority, NativeReceiver, ReceiverSnapshot)> {
    let (binding, keys, private, generation) = bootstrap.into_parts();
    let authority = Authority(Arc::new(
        AgentReceiver::for_receiver(binding.clone(), keys, generation)
            .map_err(|error| anyhow!(error))?,
    ));
    let snapshot = refresh(&authority.0).await?;
    // Native VM routes use the original IPv4 VPC endpoint. The host's inner
    // IPv6 overlay belongs to the userspace mesh, not the kernel interface.
    let socket =
        UdpSocket::bind((std::net::Ipv4Addr::UNSPECIFIED, super::mesh_cloud::CLOUD_UDP_PORT))
            .await?;
    let mut receiver = NativeReceiver::start(
        binding,
        private,
        socket,
        session,
        "127.0.0.1:22".parse()?,
        authority.0.verifier(),
    )
    .await?;
    receiver.reconcile(Some(&snapshot.native_policy())).await?;
    snapshot.time(Instant::now()).ok_or_else(|| anyhow!("cloud.receiver.policy_expired"))?;
    Ok((authority, receiver, snapshot))
}

fn renewal_at(snapshot: &ReceiverSnapshot) -> anyhow::Result<(Instant, Deadline)> {
    let expiry =
        snapshot.elapsed_deadline().ok_or_else(|| anyhow!("cloud.receiver.policy_expired"))?;
    let left = expiry.remaining().ok_or_else(|| anyhow!("cloud.receiver.policy_expired"))?;
    let delay = (left / 2).max(Duration::from_secs(1)).min(left);
    let wake = expiry
        .shortened_by(left - delay)
        .ok_or_else(|| anyhow!("cloud.receiver.policy_expired"))?;
    Ok((Instant::now() + delay, wake))
}

async fn renew(
    source: Arc<AgentReceiver>,
    send: mpsc::Sender<Option<NativePolicy>>,
    mut next: (Instant, Deadline),
) -> anyhow::Result<()> {
    let mut retry = Duration::from_secs(1);
    loop {
        // A snapshot's own renewal deadline or a failed request's backoff,
        // never a timer that polls unrelated state.
        let clock = next.1.clone();
        super::receiver_deadline::wait(next.0, Some(next.1))
            .await
            .map_err(|_| anyhow!("cloud.receiver.clock_unavailable"))?;
        match refresh(&source).await {
            Ok(snapshot) => {
                next = renewal_at(&snapshot)?;
                retry = Duration::from_secs(1);
                send.send(Some(snapshot.native_policy()))
                    .await
                    .map_err(|_| anyhow!("cloud.receiver.stopped"))?;
            }
            Err(_) => {
                if source.is_retired() {
                    return Err(anyhow!("cloud.receiver.generation_retired"));
                }
                source.invalidate();
                send.send(None).await.map_err(|_| anyhow!("cloud.receiver.stopped"))?;
                let elapsed = clock
                    .after(retry)
                    .ok_or_else(|| anyhow!("cloud.receiver.clock_unavailable"))?;
                next = (Instant::now() + retry, elapsed);
                retry = (retry * 2).min(Duration::from_secs(30));
            }
        }
    }
}

async fn run_child(parent: StdStream, control: StdStream, session: PathBuf) -> anyhow::Result<()> {
    let mut parent = UnixStream::from_std(parent)?;
    let mut control = UnixStream::from_std(control)?;
    let shutdown = super::shutdown_signal();
    tokio::pin!(shutdown);
    let elapsed = Elapsed::system()
        .and_then(|source| source.deadline_at(REQUEST_BUDGET))
        .ok_or_else(|| anyhow!("cloud.receiver.clock_unavailable"))?;
    let active = Instant::now() + REQUEST_BUDGET;
    let bootstrap = tokio::select! {
        biased;
        result = closed(&mut parent) => return result,
        result = &mut shutdown => return result,
        result = super::receiver_deadline::wait(active, Some(elapsed)) => {
            result.map_err(|_| anyhow!("cloud.receiver.clock_unavailable"))?;
            bail!("cloud.receiver.bootstrap_expired");
        },
        result = read_bootstrap(&mut control) => result?,
    };
    // No service futures exist during startup; dropping this future still
    // invalidates a prepared source read and releases the private key.
    let (authority, receiver, snapshot) = tokio::select! {
        biased;
        result = closed(&mut parent) => return result,
        result = closed(&mut control) => return result,
        result = &mut shutdown => return result,
        result = initialize(bootstrap, session) => result?,
    };
    let (send, updates) = mpsc::channel(1);
    let next = renewal_at(&snapshot)?;
    let (stop, stopped) = oneshot::channel();
    let serving = receiver.serve(updates, async {
        let _ = stopped.await;
    });
    tokio::pin!(serving);
    let mut finished = false;
    control.write_all(&[1]).await?;
    let outcome = tokio::select! {
        biased;
        result = closed(&mut parent) => result,
        result = closed(&mut control) => result,
        result = &mut shutdown => result,
        result = &mut serving => { finished = true; result },
        result = renew(authority.0.clone(), send, next) => result,
    };
    authority.0.invalidate();
    let _ = stop.send(());
    if !finished {
        serving.await?;
    }
    // The daemon must additionally reap this owned child before acknowledging
    // root park. Acknowledging frame receipt would not establish stream drain.
    control.write_all(&[2]).await?;
    outcome
}
