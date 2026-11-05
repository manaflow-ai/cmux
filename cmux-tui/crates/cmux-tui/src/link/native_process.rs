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

/// One policy read. The first read (`renewal` false) closes on any failure; a
/// renewal's intent retains the installed lease, so an unanswered renewal
/// leaves the caller to decide how long the current policy keeps serving.
async fn refresh(
    source: &Arc<AgentReceiver>,
    renewal: bool,
) -> Result<ReceiverSnapshot, ReadFailure> {
    // Intent creation belongs to the live actor, not to the blocking executor.
    // A delayed executor must never create fresh authority after role stop.
    let prepared = if renewal { source.prepare_renewal() } else { source.prepare_refresh() };
    let Ok(prepared) = prepared else {
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
        // A read still running past its budget is detached, not stopped. On a
        // renewal its intent is superseded at once, so a late reply can never
        // install a policy this loop never sent to the receiver; the new
        // intent retains the installed lease, so this closes nothing valid.
        None => {
            if renewal {
                drop(source.prepare_renewal());
            }
            Err(ReadFailure::Unanswered)
        }
        Some(Ok(Err(error))) if !is_refusal(&error) => Err(ReadFailure::Unanswered),
        _ => {
            source.invalidate();
            Err(ReadFailure::Refused)
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
    let snapshot = refresh(&authority.0, false).await.map_err(|failure| {
        // Nothing is retained before the first policy: any failure closes.
        authority.0.invalidate();
        anyhow!("cloud.receiver.policy_unavailable ({failure:?})")
    })?;
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
             ({} s left of local admission or lease), streams and peers stay up, next read in {} ms",
            took.as_millis(),
            left.as_secs(),
            retry.as_millis()
        );
    }
}

/// A snapshot's lease end on both clocks: active time and elapsed time.
fn lease_of(snapshot: &ReceiverSnapshot) -> Option<(Instant, Deadline)> {
    Some((snapshot.expires(), snapshot.elapsed_deadline()?))
}

/// What is left of a lease, by whichever clock ends it first; `None` once
/// either has run out.
fn lease_left(lease: &(Instant, Deadline), now: Instant) -> Option<Duration> {
    let active = lease.0.checked_duration_since(now).filter(|left| !left.is_zero())?;
    Some(active.min(lease.1.remaining()?))
}

/// Whether a failed read keeps the current policy, and for how long. Only a
/// read with no answer keeps it: until the local admission the control plane
/// granted (`admit_until`) ends, or else until the installed lease ends on its
/// own. A refusal, or a read past both, closes as before.
fn keeps_policy(
    failure: ReadFailure,
    admitted: Option<Instant>,
    lease: Option<&(Instant, Deadline)>,
    now: Instant,
) -> Option<Duration> {
    if failure != ReadFailure::Unanswered {
        return None;
    }
    let admission =
        admitted.and_then(|end| end.checked_duration_since(now)).filter(|left| !left.is_zero());
    let lease = lease.and_then(|lease| lease_left(lease, now));
    admission.into_iter().chain(lease).max()
}

async fn renew(
    source: Arc<AgentReceiver>,
    send: mpsc::Sender<Option<NativePolicy>>,
    mut next: (Instant, Deadline),
    mut expires: Option<Instant>,
    mut admitted: Option<Instant>,
    mut lease: Option<(Instant, Deadline)>,
) -> anyhow::Result<()> {
    let mut retry = Duration::from_secs(1);
    let mut log = RenewalLog { last_slow: None };
    loop {
        // A snapshot's own renewal deadline or a failed request's backoff,
        // never a timer that polls unrelated state.
        let clock = next.1.clone();
        super::receiver_deadline::wait(next.0, Some(next.1))
            .await
            .map_err(|_| anyhow!("cloud.receiver.clock_unavailable"))?;
        let started = Instant::now();
        match refresh(&source, true).await {
            Ok(snapshot) => {
                let arrived = Instant::now();
                let took = arrived - started;
                let lapsed = expires.and_then(|end| arrived.checked_duration_since(end));
                log.read(took, snapshot.expires() - snapshot.started(), lapsed);
                expires = Some(snapshot.admitted_until());
                admitted = snapshot.admits_locally().then(|| snapshot.admitted_until());
                lease = lease_of(&snapshot);
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
                // A read with no answer is not a revocation: the receiver's own
                // expiry of the policy it holds still ends it (at `admit_until`
                // or its lease) if no read answers before then, and reads
                // retry meanwhile, before that end.
                let wait = match keeps_policy(failure, admitted, lease.as_ref(), Instant::now()) {
                    Some(left) => {
                        let wait = retry.min(left);
                        log.kept(started.elapsed(), wait, left);
                        wait
                    }
                    None => {
                        log.failed(started.elapsed(), retry, failure);
                        expires = None;
                        admitted = None;
                        lease = None;
                        source.invalidate();
                        send.send(None).await.map_err(|_| anyhow!("cloud.receiver.stopped"))?;
                        retry
                    }
                };
                let elapsed =
                    clock.after(wait).ok_or_else(|| anyhow!("cloud.receiver.clock_unavailable"))?;
                next = (Instant::now() + wait, elapsed);
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
    let next = renewal_at(&snapshot, snapshot.started().elapsed())?;
    let expires = Some(snapshot.admitted_until());
    let admitted = snapshot.admits_locally().then(|| snapshot.admitted_until());
    let lease = lease_of(&snapshot);
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
        result = renew(authority.0.clone(), send, next, expires, admitted, lease) => result,
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
