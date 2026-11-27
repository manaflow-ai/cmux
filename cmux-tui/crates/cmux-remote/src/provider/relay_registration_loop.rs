//! The daemon side of a relay registration: its retry loop, back-off, register log and one
//! registered control socket's run (split out of `relay.rs`).

use super::*;

/// The registration's joined circuits belong to the registration, not to one
/// control socket: each is its own relay socket, which the relay keeps open
/// when the control socket closes, so a live session outlives a dropped or
/// renewed registration. They end at shutdown, or after a pause the
/// registration did not survive (their sockets died with it).
#[allow(clippy::too_many_arguments)]
pub(super) async fn run_registration_loop(
    daemon: Arc<dyn RelayIncoming>,
    config: RelayDaemonConfig,
    framing: RelayCircuitFraming,
    credentials: RelayCredentialSource,
    tls: RelayTls,
    shutdown: watch::Receiver<bool>,
    first_ready: Option<oneshot::Sender<Result<(), ProviderError>>>,
    log: Option<String>,
    state: watch::Sender<RegistrationState>,
) {
    let mut circuits = IncomingCircuitTasks::new(MAX_RELAY_INCOMING_TASKS);
    run_registration_attempts(
        daemon,
        config,
        framing,
        credentials,
        tls,
        shutdown,
        first_ready,
        log,
        &mut circuits,
        &state,
    )
    .await;
    circuits.shutdown().await;
}

#[allow(clippy::too_many_arguments)]
async fn run_registration_attempts(
    daemon: Arc<dyn RelayIncoming>,
    config: RelayDaemonConfig,
    framing: RelayCircuitFraming,
    credentials: RelayCredentialSource,
    tls: RelayTls,
    mut shutdown: watch::Receiver<bool>,
    mut first_ready: Option<oneshot::Sender<Result<(), ProviderError>>>,
    log: Option<String>,
    circuits: &mut IncomingCircuitTasks,
    state: &watch::Sender<RegistrationState>,
) {
    let mut retry = Retry::new();
    let mut log = RegisterLog::new(log, Instant::now());
    loop {
        if *shutdown.borrow() {
            return;
        }
        if shutdown.has_changed().is_err() {
            return;
        }
        let mut attempt = Attempt::default();
        let result = run_registration_once(
            daemon.clone(),
            &config,
            framing,
            &credentials,
            &tls,
            &mut shutdown,
            &mut first_ready,
            circuits,
            &mut attempt,
            &log,
            state,
        )
        .await;
        // A registration that got ready and later died (a pause, a relay
        // restart, an expired ticket) registers again from the first wait.
        if attempt.registered {
            retry.ready();
            log.dropped(Instant::now());
        }
        // What the attempt met, while the next one waits. A credential source
        // that fails (the ticket mint is down, or did not answer in its
        // bound) is a named state, not only a stderr line.
        state.send_replace(match &result {
            Ok(()) => RegistrationState::Registering,
            Err(error) if is_credential_source_error(error) => {
                RegistrationState::CredentialUnavailable { error: error.to_string() }
            }
            Err(error) => RegistrationState::RelayUnavailable { error: error.to_string() },
        });
        // A pause the registration did not survive outlived its circuits too.
        if attempt.resumed {
            circuits.shutdown().await;
        }
        let credential_failure = result.as_ref().is_err_and(is_credential_source_error);
        if first_ready.is_some()
            && result.as_ref().is_err_and(|error| !error.is_retryable_carrier_failure())
        {
            if let Some(sender) = first_ready.take() {
                let _ = sender.send(result);
            }
            return;
        }
        if *shutdown.borrow() {
            return;
        }
        let ended = if attempt.resumed {
            Ended::Resumed
        } else if credential_failure {
            Ended::Credential
        } else {
            Ended::Relay
        };
        let wait = retry.wait(ended, random_unit());
        if let (Some(label), Err(error)) = (&log.label, &result) {
            log.failures += 1;
            eprintln!(
                "{label}: attempt {} failed, retrying in {} ms: {error}",
                log.failures,
                wait.as_millis()
            );
        }
        match back_off(&mut retry, wait, &mut shutdown, wall_now).await {
            Waited::Elapsed => {}
            Waited::Resumed => {
                if let Some(label) = &log.label {
                    eprintln!("{label}: resumed during the wait; registering now");
                }
            }
            Waited::Shutdown => return,
        }
    }
}

/// What one registration attempt got to.
#[derive(Debug, Default)]
struct Attempt {
    /// It got ready (and may have ended since).
    registered: bool,
    /// It ended because the machine resumed from a pause it did not survive.
    resumed: bool,
}

/// How [`wait_unless_resumed`] ended.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Waited {
    Elapsed,
    /// The machine resumed: the wall clock jumped past the monotonic one, or
    /// the monotonic clock moved past the relay's retirement between two looks.
    Resumed,
    Shutdown,
}

/// Waits out a failed attempt's `wait`. A resume during it (the pause
/// outlived the reason for the wait) starts both backoffs over, so the next
/// failure waits the first backoff again, not the one from before the pause.
pub(super) async fn back_off(
    retry: &mut Retry,
    wait: Duration,
    shutdown: &mut watch::Receiver<bool>,
    wall: fn() -> std::time::SystemTime,
) -> Waited {
    let waited = wait_unless_resumed(wait, shutdown, wall).await;
    if waited == Waited::Resumed {
        retry.ready();
    }
    waited
}

/// Waits `wait` (monotonic, so a pause does not count), looking at the
/// clocks every [`CHECK_INTERVAL`]: a resume ends the wait at once. Ends at
/// the latest when `wait` elapses or at shutdown. `wall` is the wall clock.
async fn wait_unless_resumed(
    wait: Duration,
    shutdown: &mut watch::Receiver<bool>,
    wall: fn() -> std::time::SystemTime,
) -> Waited {
    if wait.is_zero() {
        return Waited::Elapsed;
    }
    let sleep = tokio::time::sleep(wait);
    tokio::pin!(sleep);
    let mut clocks = ClockWatch::new(Instant::now(), wall());
    let mut interval = tokio::time::interval(CHECK_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        // After a pause longer than `wait`, the sleep and the tick are both
        // ready and `select!` picks either: every wakeup looks at the clocks.
        let elapsed = tokio::select! {
            _ = &mut sleep => true,
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return Waited::Shutdown;
                }
                false
            }
            _ = interval.tick() => false,
        };
        // A wall-clock step past the monotonic one, or a monotonic gap past
        // the relay's retirement between two looks a second apart (a pause
        // where every guest clock kept running).
        let look = clocks.look(Instant::now(), wall());
        if look.wall_ahead > CLOCK_JUMP || look.outlived_relay() {
            return Waited::Resumed;
        }
        if elapsed {
            return Waited::Elapsed;
        }
    }
}

/// What a background registration writes to stderr when the relay answers
/// its Register: the first one, and each one after a drop, never a
/// heartbeat. A journey timeline reads the Register time from it.
pub(super) struct RegisterLog {
    /// The registration's stderr prefix; nothing is written without one.
    pub(super) label: Option<String>,
    /// When the registration started.
    started: Instant,
    /// Failed attempts since the last Register (or the start).
    pub(super) failures: u64,
    /// When the last registration ended, once one has.
    dropped_at: Option<Instant>,
}

impl RegisterLog {
    pub(super) fn new(label: Option<String>, started: Instant) -> Self {
        Self { label, started, failures: 0, dropped_at: None }
    }

    /// A registration that got ready has ended at `now`.
    pub(super) fn dropped(&mut self, now: Instant) {
        self.failures = 0;
        self.dropped_at = Some(now);
    }

    /// The line for a Register answered at `now` on `slot`.
    pub(super) fn registered_line(&self, slot: &str, now: Instant) -> Option<String> {
        let label = self.label.as_ref()?;
        let elapsed = now.saturating_duration_since(self.started).as_millis();
        let again = match self.dropped_at {
            Some(dropped) => {
                format!(
                    " again, {} ms after the drop,",
                    now.saturating_duration_since(dropped).as_millis()
                )
            }
            None => String::new(),
        };
        let retried = match self.failures {
            0 => String::new(),
            1 => " and 1 failed attempt".to_owned(),
            failures => format!(" and {failures} failed attempts"),
        };
        Some(format!("{label}: registered{again} on slot {slot} after {elapsed} ms{retried}"))
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_registration_once(
    daemon: Arc<dyn RelayIncoming>,
    config: &RelayDaemonConfig,
    framing: RelayCircuitFraming,
    credentials: &RelayCredentialSource,
    tls: &RelayTls,
    shutdown: &mut watch::Receiver<bool>,
    first_ready: &mut Option<oneshot::Sender<Result<(), ProviderError>>>,
    circuits: &mut IncomingCircuitTasks,
    attempt: &mut Attempt,
    log: &RegisterLog,
    state: &watch::Sender<RegistrationState>,
) -> Result<(), ProviderError> {
    let authentication = authenticate_daemon_control(config, credentials, tls);
    tokio::pin!(authentication);
    let control = tokio::select! {
        result = &mut authentication => result?,
        changed = shutdown.changed() => {
            if changed.is_err() || *shutdown.borrow() {
                return Ok(());
            }
            authentication.await?
        }
    };
    attempt.registered = true;
    state.send_replace(RegistrationState::Registered);
    if let Some(line) = log.registered_line(&config.slot, Instant::now()) {
        eprintln!("{line}");
    }
    if let Some(sender) = first_ready.take() {
        let _ = sender.send(Ok(()));
    }
    let mut socket = control.socket;
    let mut ticket = control.ticket;
    let mut standbys = standby::Standbys::new(config, framing, tls, &ticket);
    // Checked every second (relay_liveness.rs): a ping unanswered for 3 s,
    // or a resume (a wall-clock jump, or a monotonic gap past the relay's
    // 45 s between two checks), finds a dead registration in seconds.
    let mut liveness = registration_liveness(control.lease_seconds);
    let mut renew_at = control.renew_at;
    // Make-before-break: before the ticket expires a second control socket
    // registers with a fresh one. Every relay takes a Register on the slot as
    // the current registration and retires the one it replaced, so dials go to
    // the new socket from that moment; Incomings already sent on the old one
    // are still read until the relay closes it (`retiring`).
    let mut renewal: Option<Renewal<'_>> = None;
    let mut retiring: Option<RelaySocket> = None;
    let mut retire_until = Instant::now();
    let mut interval = tokio::time::interval(CHECK_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut nonce = 0_u64;
    let far = || Instant::now() + Duration::from_secs(86_400);
    loop {
        let message = tokio::select! {
            _ = circuits.join_next(), if !circuits.is_empty() => continue,
            ended = standbys.next(), if !standbys.is_empty() => {
                let Some(end) = ended else { continue };
                let end = match end {
                    standby::StandbyEnd::Paired(circuit, link) => {
                        let daemon = daemon.clone();
                        circuits.try_spawn(circuit, async move { daemon.incoming(link).await });
                        standby::StandbyEnd::Lapsed
                    }
                    other => other,
                };
                standbys.replace(&end, ticket.clone());
                continue;
            }
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() { return Ok(()) }
                continue;
            }
            _ = tokio::time::sleep_until(renew_at.unwrap_or_else(far)),
                if renew_at.is_some() && renewal.is_none() =>
            {
                renew_at = None;
                renewal = Some(Box::pin(authenticate_daemon_control(config, credentials, tls)));
                continue;
            }
            renewed = poll_some(renewal.as_mut()) => {
                renewal = None;
                match renewed {
                    Ok(control) => {
                        let old = std::mem::replace(&mut socket, control.socket);
                        ticket = control.ticket;
                        retiring = Some(old);
                        retire_until = Instant::now() + config.control_timeout;
                        liveness = registration_liveness(control.lease_seconds);
                        renew_at = control.renew_at;
                    }
                    Err(error) => {
                        if let Some(label) = &log.label {
                            eprintln!(
                                "{label}: renewing the registration failed, retrying in {} ms: \
                                 {error}",
                                RENEWAL_RETRY.as_millis()
                            );
                        }
                        renew_at = Some(Instant::now() + RENEWAL_RETRY);
                    }
                }
                continue;
            }
            message = read_some(retiring.as_mut()) => {
                match message {
                    Ok(RelayControl::Incoming { circuit, lane, generation, join_ticket }) => {
                        spawn_incoming(
                            circuits, &daemon, config, framing, tls, circuit, lane, generation,
                            join_ticket, log,
                        );
                    }
                    Ok(_) => {}
                    // Replaced: the relay closed it (after an Error), or it failed.
                    Err(_) => retiring = None,
                }
                continue;
            }
            _ = tokio::time::sleep_until(retire_until), if retiring.is_some() =>
            {
                retiring = None;
                continue;
            }
            _ = interval.tick() => {
                match liveness.check(Instant::now(), wall_now()) {
                    Check::Idle => continue,
                    Check::Stalled(gap) => {
                        if let Some(label) = &log.label {
                            eprintln!(
                                "{label}: the registration loop stalled {} ms with a ping out; \
                                 waiting for its answer again",
                                gap.as_millis()
                            );
                        }
                        continue;
                    }
                    Check::Ping => {
                        nonce = nonce.wrapping_add(1);
                        match send_control(&mut socket, &RelayControl::Ping { nonce }).await {
                            Ok(()) => continue,
                            Err(error) => Err(error),
                        }
                    }
                    Check::Dead => {
                        Err(ProviderError::Transport(
                            "relay registration stopped answering".into(),
                        ))
                    }
                    Check::Resumed => {
                        attempt.resumed = true;
                        return Err(ProviderError::Transport(
                            "relay registration did not survive a pause".into(),
                        ));
                    }
                }
            }
            message = read_control(&mut socket) => message,
        };
        let failure = match message {
            Ok(message) => {
                liveness.on_inbound();
                match message {
                    RelayControl::Incoming { circuit, lane, generation, join_ticket } => {
                        spawn_incoming(
                            circuits,
                            &daemon,
                            config,
                            framing,
                            tls,
                            circuit,
                            lane,
                            generation,
                            join_ticket,
                            log,
                        );
                        continue;
                    }
                    RelayControl::Ping { nonce } => {
                        send_control(&mut socket, &RelayControl::Pong { nonce }).await?;
                        continue;
                    }
                    RelayControl::Error { code, retryable, .. } => relay_operation_rejection(
                        &code,
                        retryable,
                        "relay registration is temporarily unavailable",
                    ),
                    _ => continue,
                }
            }
            Err(error) => error,
        };
        // The current socket ended (the relay saw the renewal's Register before
        // this socket's last read, or its ticket ran out) while a renewal is in
        // flight: the renewal decides, and the registration continues on it.
        let Some(pending) = renewal.take() else {
            return Err(failure);
        };
        let renewed = tokio::select! {
            renewed = pending => renewed,
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return Ok(());
                }
                return Err(failure);
            }
        };
        let Ok(control) = renewed else {
            return Err(failure);
        };
        socket = control.socket;
        ticket = control.ticket;
        liveness = registration_liveness(control.lease_seconds);
        renew_at = control.renew_at;
    }
}

fn registration_liveness(lease_seconds: u32) -> Liveness {
    let heartbeat = Duration::from_secs(u64::from(lease_seconds).max(3) / 3);
    Liveness::new(heartbeat, Instant::now(), wall_now())
}

/// Polls `future` when there is one, else never completes (a `select!`
/// branch's future is built even while its branch is off).
async fn poll_some<F: Future + Unpin>(future: Option<&mut F>) -> F::Output {
    match future {
        Some(future) => future.await,
        None => std::future::pending().await,
    }
}

/// Reads `socket`'s next control message when there is a socket, else never.
async fn read_some(socket: Option<&mut RelaySocket>) -> Result<RelayControl, ProviderError> {
    match socket {
        Some(socket) => read_control(socket).await,
        None => std::future::pending().await,
    }
}
