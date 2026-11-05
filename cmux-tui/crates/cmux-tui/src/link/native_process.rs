//! The receiving child has one mode, fixed by its private daemon startup.
//! It reads no user link state and never receives an account credential.
use std::os::fd::AsRawFd as _;
use std::os::unix::net::UnixStream as StdStream;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail};
use cmux_host::cloud::private_bootstrap::NativeBootstrap;
use cmux_host::cloud::receiver::{REQUEST_BUDGET, ReceiverSnapshot, is_refusal};
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

/// Why a policy read did not produce a snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReadFailure {
    /// No answer in time: the control plane (or the host agent's read of it)
    /// was slow or unreachable. Current authority is left as it was.
    Unanswered,
    /// The control plane refused, or the read could not run at all. Current
    /// authority is already closed.
    Refused,
}

async fn refresh(source: &Arc<AgentReceiver>) -> Result<ReceiverSnapshot, ReadFailure> {
    // Intent creation belongs to the live actor, not to the blocking executor.
    // A delayed executor must never create fresh authority after role stop.
    let Ok(prepared) = source.prepare_refresh() else {
        source.invalidate();
        return Err(ReadFailure::Refused);
    };
    let active = prepared.started() + REQUEST_BUDGET;
    let Some(elapsed) =
        prepared.elapsed_source().and_then(|source| source.deadline_at(REQUEST_BUDGET))
    else {
        source.invalidate();
        return Err(ReadFailure::Refused);
    };
    let reader = source.clone();
    let mut task = tokio::task::spawn_blocking(move || reader.refresh_prepared(prepared));
    let result = tokio::select! {
        biased;
        _ = super::receiver_deadline::wait(active, Some(elapsed)) => None,
        result = &mut task => Some(result),
    };
    match result {
        Some(Ok(Ok(snapshot))) => Ok(snapshot),
        // A read still running past its budget may yet publish its own
        // authenticated answer; a later read supersedes it.
        None => Err(ReadFailure::Unanswered),
        Some(Ok(Err(error))) if !is_refusal(&error) => Err(ReadFailure::Unanswered),
        _ => {
            source.invalidate();
            Err(ReadFailure::Refused)
        }
    }
}

/// Bind the receiver's socket and start its listener from the bind-time
/// bootstrap alone. No policy read blocks this: the listener admits no peer
/// and the verifier no token until the first read (`first_policy`) installs
/// one, in the background, so a machine reports ready without waiting the
/// 5 to 8 s that read takes.
async fn initialize(
    bootstrap: NativeBootstrap,
    session: PathBuf,
) -> anyhow::Result<(Authority, NativeReceiver)> {
    let (binding, keys, private, generation) = bootstrap.into_parts();
    let authority = Authority(Arc::new(
        AgentReceiver::for_receiver(binding.clone(), keys, generation)
            .map_err(|error| anyhow!(error))?,
    ));
    // Native VM routes use the original IPv4 VPC endpoint. The host's inner
    // IPv6 overlay belongs to the userspace mesh, not the kernel interface.
    let socket =
        UdpSocket::bind((std::net::Ipv4Addr::UNSPECIFIED, super::mesh_cloud::CLOUD_UDP_PORT))
            .await?;
    let receiver = NativeReceiver::start(
        binding,
        private,
        socket,
        session,
        "127.0.0.1:22".parse()?,
        authority.0.verifier(),
    )
    .await?;
    Ok((authority, receiver))
}

/// The first policy read, after the listener is up. A read with no answer
/// is retried with backoff (1 to 30 s): nothing is admitted meanwhile, and
/// nothing was before it either. A refusal closes the receiver, as a failed
/// first read always did. Then renewals take over from that snapshot.
async fn first_policy(
    source: Arc<AgentReceiver>,
    send: mpsc::Sender<Option<NativePolicy>>,
    behind: Arc<tokio::sync::Notify>,
) -> anyhow::Result<()> {
    let mut retry = Duration::from_secs(1);
    let snapshot = loop {
        let started = Instant::now();
        match refresh(&source).await {
            Ok(snapshot) => break snapshot,
            Err(failure) => {
                if source.is_retired() {
                    return Err(anyhow!("cloud.receiver.generation_retired"));
                }
                if failure == ReadFailure::Refused {
                    source.invalidate();
                    bail!("cloud.receiver.policy_unavailable ({failure:?})");
                }
                eprintln!(
                    "cmux link: receiver first policy read got no answer after {} ms; listening, retry in {} ms",
                    started.elapsed().as_millis(),
                    retry.as_millis()
                );
                tokio::time::sleep(retry).await;
                retry = (retry * 2).min(Duration::from_secs(30));
            }
        }
    };
    snapshot.time(Instant::now()).ok_or_else(|| anyhow!("cloud.receiver.policy_expired"))?;
    let next = renewal_at(&snapshot, snapshot.started().elapsed())?;
    let expires = Some(snapshot.admitted_until());
    let admitted = snapshot.admits_locally().then(|| snapshot.admitted_until());
    send.send(Some(snapshot.native_policy()))
        .await
        .map_err(|_| anyhow!("cloud.receiver.stopped"))?;
    renew(source, send, next, expires, admitted, behind).await
}

/// When to start the next policy read: early enough that it lands before the
/// current lease ends. `took` is how long the last read ran; the next one is
/// started at least one and a half of that (plus a second) before expiry, and
/// never later than halfway through what is left. A read slower than a third
/// of the lease used to land after the lease ended every time, so the receiver
/// dropped every stream and peer once per renewal (cmux link dials then saw
/// `unreachable`, and open connections ended about every 27 s).
fn renewal_at(snapshot: &ReceiverSnapshot, took: Duration) -> anyhow::Result<(Instant, Deadline)> {
    let expiry =
        snapshot.elapsed_deadline().ok_or_else(|| anyhow!("cloud.receiver.policy_expired"))?;
    let left = expiry.remaining().ok_or_else(|| anyhow!("cloud.receiver.policy_expired"))?;
    let delay = renewal_delay(left, took);
    let wake = expiry
        .shortened_by(left - delay)
        .ok_or_else(|| anyhow!("cloud.receiver.policy_expired"))?;
    Ok((Instant::now() + delay, wake))
}

/// The wait before the next read, with `left` of the lease remaining and the
/// last read having taken `took`. Never under a quarter second (one read runs
/// at a time, so this bounds a fast read's rate), nor past the end.
fn renewal_delay(left: Duration, took: Duration) -> Duration {
    let lead = (took + took / 2 + Duration::from_secs(1)).max(left / 2).min(left);
    (left - lead).max(Duration::from_millis(250)).min(left)
}

/// One stderr line (the host's journal) for a renewal worth a look: a failed
/// read, or one whose policy came after the previous lease had ended. A slow
/// read is reported at most once a minute. Ids and timings only.
struct RenewalLog {
    last_slow: Option<Instant>,
}

impl RenewalLog {
    fn read(&mut self, took: Duration, lifetime: Duration, lapsed: Option<Duration>) {
        if let Some(gap) = lapsed {
            eprintln!(
                "cmux link: receiver policy read took {} ms and arrived {} ms after the previous \
                 lease ended ({} ms lease); streams and peers were closed meanwhile",
                took.as_millis(),
                gap.as_millis(),
                lifetime.as_millis()
            );
            return;
        }
        let slow = took * 3 > lifetime;
        let due = self.last_slow.is_none_or(|at| at.elapsed() >= Duration::from_secs(60));
        if slow && due {
            self.last_slow = Some(Instant::now());
            eprintln!(
                "cmux link: receiver policy read took {} ms of a {} ms lease",
                took.as_millis(),
                lifetime.as_millis()
            );
        }
    }

    fn failed(&self, took: Duration, retry: Duration, failure: ReadFailure) {
        eprintln!(
            "cmux link: receiver policy read failed after {} ms ({}); streams and peers closed, \
             next read in {} ms",
            took.as_millis(),
            match failure {
                ReadFailure::Unanswered => "no answer",
                ReadFailure::Refused => "refused",
            },
            retry.as_millis()
        );
    }

    /// Local admission kept the current policy through a read with no answer.
    fn kept(&self, took: Duration, retry: Duration, left: Duration) {
        eprintln!(
            "cmux link: receiver policy read got no answer after {} ms; kept the current policy \
             (local admission, {} s left), streams and peers stay up, next read in {} ms",
            took.as_millis(),
            left.as_secs(),
            retry.as_millis()
        );
    }
}

/// Whether a failed read keeps the current policy: only a read with no answer,
/// only under local admission the control plane granted (`admit_until`), and
/// only while that admission lasts. Every other failure closes as before.
fn keeps_policy(failure: ReadFailure, admitted: Option<Instant>, now: Instant) -> Option<Duration> {
    match (failure, admitted) {
        (ReadFailure::Unanswered, Some(end)) => {
            end.checked_duration_since(now).filter(|left| !left.is_zero())
        }
        _ => None,
    }
}

/// The least time between two policy reads that a token naming newer peer
/// authority starts early, so a burst of such tokens costs one read.
const EARLY_READ_GAP: Duration = Duration::from_secs(2);

async fn renew(
    source: Arc<AgentReceiver>,
    send: mpsc::Sender<Option<NativePolicy>>,
    mut next: (Instant, Deadline),
    mut expires: Option<Instant>,
    mut admitted: Option<Instant>,
    behind: Arc<tokio::sync::Notify>,
) -> anyhow::Result<()> {
    let mut retry = Duration::from_secs(1);
    let mut log = RenewalLog { last_slow: None };
    let mut last_read = Instant::now();
    loop {
        // A snapshot's own renewal deadline or a failed request's backoff,
        // never a timer that polls unrelated state. A token the control plane
        // minted against newer peer authority than this policy (the verifier's
        // `on_policy_behind`) starts the read early.
        let clock = next.1.clone();
        let early = async {
            behind.notified().await;
            let floor = (last_read + EARLY_READ_GAP).min(next.0);
            tokio::time::sleep_until(floor.into()).await;
        };
        tokio::select! {
            biased;
            result = super::receiver_deadline::wait(next.0, Some(next.1)) => {
                result.map_err(|_| anyhow!("cloud.receiver.clock_unavailable"))?;
            }
            () = early => eprintln!(
                "cmux link: receiver policy read early: a token named newer peer authority than the current policy"
            ),
        }
        let started = Instant::now();
        last_read = started;
        match refresh(&source).await {
            Ok(snapshot) => {
                let arrived = Instant::now();
                let took = arrived - started;
                let lapsed = expires.and_then(|end| arrived.checked_duration_since(end));
                log.read(took, snapshot.expires() - snapshot.started(), lapsed);
                expires = Some(snapshot.admitted_until());
                admitted = snapshot.admits_locally().then(|| snapshot.admitted_until());
                next = renewal_at(&snapshot, took)?;
                retry = Duration::from_secs(1);
                send.send(Some(snapshot.native_policy()))
                    .await
                    .map_err(|_| anyhow!("cloud.receiver.stopped"))?;
            }
            Err(failure) => {
                if source.is_retired() {
                    return Err(anyhow!("cloud.receiver.generation_retired"));
                }
                if let Some(left) = keeps_policy(failure, admitted, Instant::now()) {
                    // The receiver's own expiry of this policy still ends it at
                    // `admit_until` if no read answers before then.
                    log.kept(started.elapsed(), retry, left);
                } else {
                    log.failed(started.elapsed(), retry, failure);
                    expires = None;
                    admitted = None;
                    source.invalidate();
                    send.send(None).await.map_err(|_| anyhow!("cloud.receiver.stopped"))?;
                }
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
    let (authority, receiver) = tokio::select! {
        biased;
        result = closed(&mut parent) => return result,
        result = closed(&mut control) => return result,
        result = &mut shutdown => return result,
        result = initialize(bootstrap, session) => result?,
    };
    let behind = Arc::new(tokio::sync::Notify::new());
    let hint = behind.clone();
    authority.0.verifier().on_policy_behind(move || hint.notify_one());
    let (send, updates) = mpsc::channel(1);
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
        result = first_policy(authority.0.clone(), send, behind) => result,
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

#[cfg(test)]
#[path = "native_process_tests.rs"]
mod tests;
